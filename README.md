mongoscripts
============

Useful Scripts for working with MongoDB

### getShardingDiags.sh ###

This script will connect to a sharded cluster, retrieve all of the 
interesting and useful diagnostic information I could think of, and 
put it all in a neat file in /tmp.

Usage:

    ./getShardingDiags.sh --host $MONGOS_HOST --port $PORT 

 * Replace $MONGOS__HOST with the hostname where a 'mongos' process is running
 * Replace $PORT with the port number that this 'mongos' is listening to

Requirements:
       
 * BASH shell
 * The 'mongo' shell and 'mongodump' must be installed in the $PATH of the user running the script
 * Only tested on OSX so far -- beware bugs!

Information collected:
 
 * 'conf' directory
     * Contents of the collections, databases, locks, lockpings, mongos, settings, shards, and tags collections from the config database
     * A 'mongodump' of the config database
     * The output of 'sh.status(true)'

 * 'db' directory
     * Collection stats() and indexes for every collection in every database in the cluster

 * 'SHARD-*' directory
     * There is one such directory for each shard in the cluster
     * This directory contains the following information from the primary for the shard:
         * db.serverStatus()
         * Connection pool stats
         * db.currentOP()
         * As much of the log file as is in the internal capped collection
     * If the shard is a replica set, this directory will also contain the following information from the primary node:
         * rs.status()
         * Replication information

 * 'mongos-*' directory
     * There is one such directory for each 'mongos' listed in the config database
     * This directory contains the same information for each 'mongos' that is collected for a standalone shard

