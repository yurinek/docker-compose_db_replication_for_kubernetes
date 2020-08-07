#!/bin/bash

export RUNTIME_ENV_PG_CLUSTER_NAME=$(basename $RUNTIME_ENV_PG_CLUSTER_PATH)

if [ -d $RUNTIME_ENV_PG_CLUSTER_PATH/base ]; then 
    echo "########## Postgres data files in directory $RUNTIME_ENV_PG_CLUSTER_PATH exist, will skip Cluster creation..."  
    echo "########## Creating only Postgres Cluster configuration for $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME ..."
    # its not possible to create new cluster if its data files exist, so using dummy cluster name
    dummy_path=$(dirname $RUNTIME_ENV_PG_CLUSTER_PATH)
    if [ $dummy_path == "/" ]; then
        dummy_path=""
    fi
    mkdir -p $dummy_path/dummy
    chown -R postgres. $dummy_path/dummy
    su postgres -c "/usr/bin/pg_createcluster -p $RUNTIME_ENV_PG_PORT -d $dummy_path/dummy $RUNTIME_ENV_PG_VERSION_PULL dummy"
    rm -rf $dummy_path/dummy
    mv /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/dummy /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME
    sed -i "s/dummy/$RUNTIME_ENV_PG_CLUSTER_NAME/g" /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/postgresql.conf
else 
    echo "########## Creating Postgres Cluster $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME ..." 
    mkdir -p $RUNTIME_ENV_PG_CLUSTER_PATH
    chown -R postgres. $RUNTIME_ENV_PG_CLUSTER_PATH
    su postgres -c "/usr/bin/pg_createcluster -p $RUNTIME_ENV_PG_PORT -d $RUNTIME_ENV_PG_CLUSTER_PATH $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME"
fi

sleep 1
su postgres -c "/usr/bin/pg_lsclusters"

echo "########## Starting Postgres Cluster $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME ..." 
su postgres -c "/usr/bin/pg_ctlcluster $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME start"
su postgres -c "/usr/bin/pg_lsclusters"

echo "########## Configuring Master Database to be Replication aware ..."

echo "
wal_level = 'logical'
track_commit_timestamp = on 
archive_mode = on 
archive_command = '/bin/true'
max_wal_senders = 4
max_replication_slots = 4
wal_sender_timeout = 14400000
wal_keep_segments = 10
wal_buffers = 16MB
max_wal_size = 1536MB
checkpoint_completion_target=0.9
checkpoint_timeout = 30min" >> /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/postgresql.conf

# in on premise Kubernetes its not predictable which ip ranges are assigned to pods
# moreover external access to database is handled by the node port service
# thats why ip access in pg_hba.conf doesnt need to be restricted
echo "host all         postgres   0.0.0.0/0 md5" >> /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/pg_hba.conf
echo "host replication replicator 0.0.0.0/0 md5" >> /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/pg_hba.conf

chown postgres. /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/postgresql.conf
chown postgres. /etc/postgresql/$RUNTIME_ENV_PG_VERSION_PULL/$RUNTIME_ENV_PG_CLUSTER_NAME/pg_hba.conf

su postgres -c 'echo "*:*:*:*:${POSTGRES_PASSWORD}" >> ~/.pgpass'
su postgres -c 'chmod go-rw ~/.pgpass'

echo "########## Reloading Postgres Cluster $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME ..." 
/usr/bin/pg_ctlcluster $RUNTIME_ENV_PG_VERSION_PULL $RUNTIME_ENV_PG_CLUSTER_NAME reload

# dont use "su -" to preserve roots environment variables
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT -c 'create database $RUNTIME_ENV_PG_DB;'"
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT -c \"alter user postgres password '$POSTGRES_PASSWORD';\""
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT -c \"create user replicator password '$POSTGRES_PASSWORD' replication;\""
su postgres -c "echo \"create user replicator password '$POSTGRES_PASSWORD' replication;\" >/var/tmp/pw.txt"
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT $RUNTIME_ENV_PG_DB -c 'create table test (id int);'"
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT $RUNTIME_ENV_PG_DB -c 'insert into test values (1);'"
su postgres -c "psql -p $RUNTIME_ENV_PG_PORT $RUNTIME_ENV_PG_DB -c 'insert into test values (2);'"


# let this process run so container keeps running
# for "docker run" and "docker-compose" /bin/bash would be fine, but for "docker swarm" process needs to run in foreground, otherwise container will exit and would be recreated in endless loop
sleep infinity
