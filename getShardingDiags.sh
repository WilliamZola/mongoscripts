
#
# Fetch diagnostic information for a MongoDB sharded cluster and
#  save it into a set of files
#

DEBUG=true
DEBUG=

function debug()
{
    if [[ $DEBUG ]] 
    then
        echo "$@" 1>&2
    fi
}

#
# Error reporting
#
PROG=$0
function err_exit()
{
    echo "$PROG: Error: $@: exiting"
    exit 1
}

function err_arguments()
{
    if [ $ARG -lt 1 ]
    then
        echo -e "Please examine the usage options for this script - you need some arguments!\n\n"
        usage
        exit 1
    fi
}

function usage()
{
    echo "usage:
     --host       : host to connect to (default 'localhost')
     --port       : connect to this port
     -h --help    : print this message "
}

#
# Used globally 
#
HOST=localhost
PORT=
ARG=$#

function run_mongo_command() {
    debug "run_mongo_command:" "command='$@'"
    mongo --quiet --host $HOST --port $PORT << EOF
    $@
EOF
}

function run_mongo_command_withhost() {
    local host=$1
    shift
    debug "run_mongo_command_withhost:" "host=$host" "command=$@"
    mongo --quiet --host $host << EOF
    $@
EOF
}


function check_for_mongos() {
    local res
    debug "check_for_mongos:"
    which mongo > /dev/null || err_exit "'mongo' not in \$PATH"

    res=$(run_mongo_command "db.isMaster().msg")
    [[ $res == "isdbgrid" ]] || err_exit "did not connect to a 'mongos': isMaster().msg=$res"
}

function check_for_mongodump() {
    which mongodump > /dev/null || err_exit "'mongodump' not in \$PATH"
}

function parse_arguments ()
{
    debug "parse_arguments: $@"
    PROG=$0

    for i in $@
    do
        case $i in
            --host)
                HOST=$2
                shift 2
                ;;
            --host=*)
                HOST=${1#*=} 
                shift
                ;;
            -p|--port)
                PORT=$2
                shift 2
                ;;
            --port=*)
                PORT=${1#*=} 
                shift
                ;;
            -h|--help) 
                usage
                exit 1;;
        esac
    done
    debug "parse_arguments:" "HOST=$HOST", "PORT=$PORT" ;
    [[ -z $HOST ]] && err_exit "missing parameter --host "
    [[ -z $PORT ]] && err_exit "missing parameter --port "

    check_for_mongos
    check_for_mongodump
}

function build_dumpdir() {
    local host=$1
    local dumpdir=/tmp/$host
    debug "build_dumpdir" "dumpdir=$dumpdir"
    mkdir $dumpdir || { echo ""; return; }
    echo $dumpdir
}

function dump_config_information() {
    local outdir=$1/config
    local cmd
    debug "dump_config_information" "outdir=$outdir" 

    mkdir $outdir

    for i in collections databases locks lockpings mongos settings shards tags
    do
        cmd="use config
        DBQuery.shellBatchSize=5000
        print( 'contents of: $i' );
        db.$i.find()"
        run_mongo_command "$cmd" | tail +3 > $outdir/$i.txt
    done

    # serverStatus
    run_mongo_command "db.serverStatus()" > $outdir/serverStatus.txt

    # serverBuildInfo
    run_mongo_command "db.serverBuildInfo()" > $outdir/serverBuildInfo.txt

    # sh.status()
    run_mongo_command "sh.status(true)" > $outdir/shardingStatus.txt

    # Config db
    debug "mongodump -h ${HOST}:${PORT} --out $outdir -d config"
    mongodump -h ${HOST}:${PORT} --out $outdir -d config > $outdir/mongodump.log
}


function dump_collection_information() {
    local outdir=$1/db
    local tmpfile=/tmp/sh$$.js
    debug "dump_collection_information" "outdir=$outdir" "tmpfile=$tmpfile"
    mkdir $outdir

    #
    # Find all the databases that 'mongos' knows about
    #
    echo "db.adminCommand('listDatabases').databases.forEach(function(d){print(d.name)})" > $tmpfile
    local dbs=$(mongo --quiet --host $HOST --port $PORT $tmpfile)

    #
    # Print stats & index info for each collection in that database
    #  Each database's information goes into a separate file
    #
    for i in $dbs
    do
        local dbfile=$outdir/$i.txt
        # build the query for all collections in this database
        cat << EOF > $tmpfile
        mdb = db.getSiblingDB("$i")
        printjson(mdb.stats())
        mdb.getCollectionNames().forEach(function(coll) {
            printjson(mdb[coll]);
            if ( typeof mdb[coll] != "function" ) {
                printjson(mdb[coll].stats());
                printjson(mdb[coll].getIndexes());
            }
       })
EOF
        # run it
        mongo --quiet --host $HOST --port $PORT $tmpfile > $dbfile
    done

    rm -f $tmpfile
}

function get_shards() {
    local tmpfile=/tmp/sh$$.js

    debug "get_shards"
    cat > $tmpfile << EOF 
    c = db.getSiblingDB("config").shards.find();
    while (c.hasNext()) { 
        doc = c.next(); 
        // if the shard isn't a replica set, prepend the shard _id
        if ( doc.host.indexOf('/') == -1 )
            print( doc._id+"#"+doc.host );
        else
            print(doc.host) ;           // use replica set name as shard name
    } 
EOF
    res=$(mongo --quiet --host $HOST --port $PORT $tmpfile)
    rm -f $tmpfile

    debug "res='$res'"
    echo $res
}

function find_primary() {
#
# Todo: make this work when first node listed for RS is down 
#
    local host=$1
    local tmpfile=/tmp/sh$$.js
    debug "find_primary: host=$host tmpfile=$tmpfile"
    cat << EOF > $tmpfile
    x = rs.status()
    x.members.forEach( function( doc ) { if(doc.stateStr == "PRIMARY") print (doc.name) } );
EOF
    mongo --quiet --host $host $tmpfile
    rm -f $tmpfile
}

function dump_one_node() {
    local outdir=$1
    local host=$2
    debug "dump_one_node:" "outdir=$outdir" "host=$host"

    mkdir $outdir

    run_mongo_command_withhost $host "db.serverStatus()" > $outdir/serverStatus.txt
    run_mongo_command_withhost $host "db.runCommand({connPoolStats:1});" > $outdir/connectionpool.txt
    run_mongo_command_withhost $host "db.currentOP()" > $outdir/currentOP.txt
    run_mongo_command_withhost $host "db.adminCommand({hostInfo:1})" > $outdir/hostInfo.txt
    run_mongo_command_withhost $host "db.adminCommand({getLog:'global'})" > $outdir/globalLog.txt
}

function dump_one_shard_rs() {
    local outdir=$1
    local primary=$2
    debug "dump_one_shard_rs:" "outdir=$outdir" "primary=$primary"

    # Per-node stuff: also creates $outdir
    dump_one_node $outdir $primary

    # replication stuff
    run_mongo_command_withhost $primary "rs.status()" > $outdir/rsStatus.txt
    run_mongo_command_withhost $primary "db.printReplicationInfo()" > $outdir/replication.txt
    echo "========" >> $outdir/replication.txt
    run_mongo_command_withhost $primary "db.printSlaveReplicationInfo()" >> $outdir/replication.txt

}

function dump_shard_information() {
    local outdir=$1
    shift
    debug "dump_shard_information:" "outdir=$outdir" "shards=$@"
    local setname members firstnode primary shardname host

    for i do
        case $i in
            */*)  
                debug "handle replica set"
                setname=$(dirname $i)
                members=$(basename $i)
                firstnode=${members%%,*}
                primary=$(find_primary $firstnode)
                dump_one_shard_rs $outdir/SHARD-$setname $primary

                ;;
            *#*) debug "handle non-replica set"
                # Pick apart what was built in get_shards()
               shardname=${i%%#*}               # shard name is before the '#'
               host=${i##*#}                    # host name & port is after it
               dump_one_node $outdir/SHARD-$shardname $host
                ;;
            *) err_exit "dump_shard_information: cannot happen!"
                ;;
        esac
    done
}

function get_mongos() {
    local tmpfile=/tmp/sh$$.js

    debug "get_mongos"
    cat > $tmpfile << EOF 
    c = db.getSiblingDB("config").mongos.find({},{_id:1});
    while (c.hasNext()) { 
        doc = c.next(); 
        print(doc._id) ;           
    } 
EOF
    res=$(mongo --quiet --host $HOST --port $PORT $tmpfile)
    rm -f $tmpfile

    debug "res='$res'"
    echo $res
}

function dump_mongos_information() {
    local outdir=$1
    shift
    debug "dump_mongos_information:" "outdir=$outdir" "mongos=$@"

    local mongosname

    declare -i i=0
    for mongos do
        mongosname="mongos-$((i++))"
        dump_one_node $outdir/$mongosname $mongos
    done

}

#
# main()
#

err_arguments

parse_arguments $@

MYHOST=$(hostname)
DUMPDIR=$(build_dumpdir $MYHOST)
debug "DUMPDIR=$DUMPDIR"
[[ -z $DUMPDIR ]] && err_exit "could not create output directory"


dump_config_information "$DUMPDIR"
dump_collection_information "$DUMPDIR"

SHARDS=$(get_shards)
debug "SHARDS=$SHARDS"
dump_shard_information "$DUMPDIR" $SHARDS

MONGOS=$(get_mongos)
debug "MONGOS=$MONGOS"
dump_mongos_information "$DUMPDIR" $MONGOS

# Build aggregate file
tar -cz -C /tmp -f /tmp/$MYHOST-MONGOS-CFG.tgz  $MYHOST
