
#
# Fetch diagnostic information for a MongoDB sharded cluster and
#  save it into a set of files
#

DEBUG=true
DEBUG=

VERSION=0.3.0


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

function usage()
{
    echo "usage:
     --host       : host to connect to (default 'localhost')
     --port       : connect to this port
     --user       : username for authentication
     --password   : password for authentication
     -h --help    : print this message "
}

#
# Used globally 
#
HOST=localhost
PORT=
ARG=$#
#
# Globals for authentication
#
G_AUTH=


function run_mongo_command() {
    local tmpfile=/tmp/js$$.js
    debug "run_mongo_command:" "tmpfile=$tmpfile" "command='$@'"
    cat << EOF > $tmpfile
    $@
EOF
    mongo $G_AUTH --norc --quiet --host $HOST --port $PORT $tmpfile
    rm -f $tmpfile
}

function run_mongo_command_withhost() {
    local tmpfile=/tmp/js$$.js
    local host=$1
    shift
    debug "run_mongo_command_withhost:" "host=$host" "command=$@"
    cat << EOF > $tmpfile
    $@
EOF
    mongo $G_AUTH --norc --quiet --host $host $tmpfile
    rm -f $tmpfile
}

function run_1mongo_command() {
    local host=$1
    local command=$2

    command="printjson($command)"
    debug "run_1mongo_command:" "host=$host" "command=$command"
    run_mongo_command_withhost $host "$command"
}


function check_for_mongos() {
    local res
    debug "check_for_mongos:"
    which mongo > /dev/null || err_exit "'mongo' not in \$PATH"

    res=$(run_mongo_command "print(db.isMaster().msg)")
    [[ $res == "isdbgrid" ]] || err_exit "did not connect to a 'mongos': isMaster().msg=$res"
}

function check_for_mongodump() {
    which mongodump > /dev/null || err_exit "'mongodump' not in \$PATH"
}

function check_auth() {
    local user=$1
    local passwd=$2
    debug "check_auth: user=$user passwd=$passwd"

    [[ $user && -z $passwd ]] && err_exit "You must use either both or neither of --user and --password "
    [[ -z $user && $passwd ]] && err_exit "You must use either both or neither of --user and --password "

    [[ $user && $passwd ]] && G_AUTH="-u $user -p $passwd --authenticationDatabase admin"

}

function parse_arguments ()
{
    debug "parse_arguments: $@"
    PROG=$0
    local l_user=
    local l_pass=

    if [ $ARG -lt 1 ]
    then
        echo -e "Please examine the usage options for this script - you need some arguments!\n"
        usage
        exit 1
    fi

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
            -u|--user)
                l_user=$2
                shift 2
                ;;
            --user=*)
                l_user=${1#*=}
                shift
                ;;
            -p|--password)
                l_pass=$2
                shift 2
                ;;
            --password=*)
                l_pass=${1#*=}
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
                exit 0;;
            -v|--version) 
                echo "$VERSION"
                exit 0;;
        esac
    done
    debug "parse_arguments:" "HOST=$HOST", "PORT=$PORT"
    [[ -z $HOST ]] && err_exit "missing parameter --host "
    [[ -z $PORT ]] && err_exit "missing parameter --port "

    check_auth $l_user $l_pass
    debug "parse_arguments:" "l_user=$l_user" "l_pass=$l_pass" "G_AUTH=$G_AUTH" ;
    check_for_mongos
    check_for_mongodump
}

function build_dumpdir() {
    local host=$1
    local dumpdir=/tmp/$host
    debug "build_dumpdir" "dumpdir=$dumpdir"
    #
    # Todo -- better error message if directory already exists
    #
    rm -rf $dumpdir
    mkdir $dumpdir || { echo ""; return; }
    echo $dumpdir
}

function dump_one_config_collection() {
    local outfile=$1
    local collection=$2
    debug "dump_one_config_collection" "outfile=$outfile" "collection=$collection"

    echo "contents of $collection" > $outfile

    local cmd="
      cdb = db.getSiblingDB('config');
      cur = cdb.$collection.find();
      while (cur.hasNext() ) { 
	doc = cur.next();
	printjson(doc);
      }
    ";
    run_mongo_command "$cmd" >> $outfile
}

function dump_config_information() {
    local outdir=$1/config
    local cmd
    debug "dump_config_information" "outdir=$outdir" 

    mkdir $outdir

    for i in collections databases locks lockpings mongos settings shards tags
    do
	dump_one_config_collection $outdir/$i.txt $i
    done

    # serverStatus
    run_mongo_command "printjson(db.serverStatus())" > $outdir/serverStatus.txt

    # serverBuildInfo
    run_mongo_command "printjson(db.serverBuildInfo())" > $outdir/serverBuildInfo.txt

    # sh.status()
    run_mongo_command "sh.status(true)" > $outdir/shardingStatus.txt

    # Config db
    debug "mongodump -h ${HOST}:${PORT} $G_AUTH --out $outdir -d config"
    mongodump -h ${HOST}:${PORT} $G_AUTH --out $outdir -d config > $outdir/mongodump.log
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
    local dbs=$(mongo $G_AUTH --quiet --host $HOST --port $PORT $tmpfile)

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
        mongo $G_AUTH --norc --quiet --host $HOST --port $PORT $tmpfile > $dbfile
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
    res=$(mongo $G_AUTH --quiet --host $HOST --port $PORT $tmpfile)
    status=$?
    debug "status=$status"
    [[ $status == 0 ]] || err_exit ""
    rm -f $tmpfile

    debug "res='$res'"
    echo $res
}

function check_connectivity() {
    debug "check_connectivity: args='$@'"
    [[ -n $1 ]] || err_exit "No information about shards!"

    local conn

    for i do
        debug "i=$i"
        case $i in
            */*)
                debug "handle replica set"
                conn=$(basename $i)
                ;;
            *#*)
                debug "handle non-replica set"
                # Pick apart what was built in get_shards()
                # host name & port is after shard name
                conn=${i##*#}
                ;;
            *) err_exit "check_connectivity: cannot happen!"
                ;;
        esac
        debug "connecting to $conn"
        res=$(mongo $G_AUTH --quiet $conn --eval 'rs.slaveOk(); db.system.indexes.count()')
        status=$?
        debug "status='$status', res='$res'"
        [[ $status == 0 ]] || return $status
    done

    return 0
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
    res=$(mongo $G_AUTH --quiet --host $host $tmpfile)
    rm -f $tmpfile
    echo $res
}

function dump_one_node() {
    local outdir=$1
    local host=$2
    debug "dump_one_node:" "outdir=$outdir" "host=$host"

    mkdir $outdir

    res=$(mongo $G_AUTH --quiet --host $host --eval 'rs.slaveOk(); db.system.count()')
    status=$?
    debug "status='$status', res='$res'"
    [[ $status == 0 ]] || { echo "unable to contact $host; $res" > $outdir/connectivity.txt; return $status; }

    run_1mongo_command $host "db.serverCmdLineOpts()" > $outdir/serverInfo.txt
    run_1mongo_command $host "db.serverBuildInfo()" >> $outdir/serverInfo.txt
    run_1mongo_command $host "db.serverStatus()" > $outdir/serverStatus.txt
    run_1mongo_command $host "db.runCommand({connPoolStats:1})" > $outdir/connectionpool.txt
    run_1mongo_command $host "db.currentOP()" > $outdir/currentOP.txt
    run_1mongo_command $host "db.adminCommand({hostInfo:1})" > $outdir/hostInfo.txt
    run_1mongo_command $host "db.adminCommand({getLog:'global'})" > $outdir/globalLog.txt
}

function dump_one_shard_rs() {
    local outdir=$1
    local primary=$2
    debug "dump_one_shard_rs:" "outdir=$outdir" "primary=$primary"

    # Per-node stuff: also creates $outdir
    dump_one_node $outdir $primary

    # replication stuff
    run_1mongo_command $primary "rs.status()" > $outdir/rsStatus.txt
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
    ago = new Date(Date.now() - 2 * 60 * 1000);
    c = db.getSiblingDB("config").mongos.find({ping: {\$gte: ago} },{_id:1});
    while (c.hasNext()) {
        doc = c.next();
        print(doc._id);
    } 
EOF
    res=$(mongo $G_AUTH --quiet --host $HOST --port $PORT $tmpfile)
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

#
# Check arguments and create output directory
#
parse_arguments $@

MYHOST=$(hostname)
DUMPDIR=$(build_dumpdir $MYHOST)
debug "DUMPDIR=$DUMPDIR"
[[ -z $DUMPDIR ]] && err_exit "could not create output directory $DUMPDIR"


#
# Get list of shards; check connectivity to all of them 
#   (Especially important if running with authentication)
#
SHARDS=$(get_shards) || err_exit "Cannot read config.shards collection"
debug "SHARDS=$SHARDS"
check_connectivity $SHARDS || err_exit "Cannot connect to all shards"

#
# Fetch and save metadata
#
dump_config_information "$DUMPDIR"
dump_collection_information "$DUMPDIR"

#
# Fetch and save information about each shard
#
dump_shard_information "$DUMPDIR" $SHARDS

#
# Fetch and save information about each 'mongos'
#
MONGOS=$(get_mongos)
debug "MONGOS=$MONGOS"
dump_mongos_information "$DUMPDIR" $MONGOS

#
# Save it all in a single file
#
DEST=/tmp/$MYHOST-SHARDINFO.tgz
tar -cz -C /tmp -f $DEST $MYHOST

echo "Diagnostic information has been stored in $DEST"
