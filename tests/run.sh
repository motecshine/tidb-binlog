#!/bin/sh

set -eu

OUT_DIR=/tmp/tidb_binlog_test

mkdir $OUT_DIR || true
# to the dir of this script
cd "$(dirname "$0")"

pwd=$(pwd)

export PATH=$PATH:$pwd/_utils
export PATH=$PATH:$(dirname $pwd)/bin


clean_data() {
	rm -rf $OUT_DIR/pd || true
	rm -rf $OUT_DIR/tidb || true
	rm -rf $OUT_DIR/tikv || true
	rm -rf $OUT_DIR/pump || true
	rm -rf $OUT_DIR/data.drainer || true
}

stop_services() {
    killall -9 tikv-server || true
    killall -9 pd-server || true
    killall -9 tidb-server || true

    killall -9 pump || true
    killall -9 drainer || true
}

start_services() {
    stop_services
	clean_data

    echo "Starting PD..."
    pd-server \
        --client-urls http://127.0.0.1:2379 \
        --log-file "$OUT_DIR/pd.log" \
        --data-dir "$OUT_DIR/pd" &
    # wait until PD is online...
    while ! curl -o /dev/null -sf http://127.0.0.1:2379/pd/api/v1/version; do
        sleep 1
    done

    # Tries to limit the max number of open files under the system limit
    cat - > "$OUT_DIR/tikv-config.toml" <<EOF
[rocksdb]
max-open-files = 4096
[raftdb]
max-open-files = 4096
[raftstore]
# true (default value) for high reliability, this can prevent data loss when power failure.
sync-log = false
EOF

    echo "Starting TiKV..."
    tikv-server \
        --pd 127.0.0.1:2379 \
        -A 127.0.0.1:20160 \
        --log-file "$OUT_DIR/tikv.log" \
        -C "$OUT_DIR/tikv-config.toml" \
        -s "$OUT_DIR/tikv" &
    sleep 1


    echo "Starting Pump..."
	run_pump &

	sleep 5


    echo "Starting TiDB..."
    tidb-server \
        -P 4000 \
        --store tikv \
        --path 127.0.0.1:2379 \
		--enable-binlog=true \
        --log-file "$OUT_DIR/tidb.log" &

    echo "Verifying TiDB is started..."
    i=0
    while ! mysql -uroot -h127.0.0.1 -P4000 --default-character-set utf8 -e 'select * from mysql.tidb;'; do
        i=$((i+1))
        if [ "$i" -gt 40 ]; then
            echo 'Failed to start TiDB'
            exit 1
        fi
        sleep 3
    done

    echo "Starting Downstream TiDB..."
    tidb-server \
        -P 3306 \
		--path=$OUT_DIR/tidb \
		--status=20080 \
        --log-file "$OUT_DIR/down_tidb.log" &

    echo "Verifying Downstream TiDB is started..."
    i=0
    while ! mysql -uroot -h127.0.0.1 -P3306 --default-character-set utf8 -e 'select * from mysql.tidb;'; do
        i=$((i+1))
        if [ "$i" -gt 10 ]; then
            echo 'Failed to start TiDB'
            exit 1
        fi
        sleep 3
    done

	echo "Starting Drainer..."
	run_drainer &
}

trap stop_services EXIT
start_services

if [ "${1-}" = '--debug' ]; then
    echo 'You may now debug from another terminal. Press [ENTER] to continue.'
    read line
fi

# set to the case name you want to run only for debug
do_case=""

for script in ./*/run.sh; do
	test_name="$(basename "$(dirname "$script")")"
	if [[ $do_case != "" && $test_name != $do_case ]]; then
		continue
	fi

    echo "Running test $script..."
    PATH="$pwd/../bin:$pwd/_utils:$PATH" \
	OUT_DIR=$OUT_DIR \
    TEST_NAME=$test_name \
    sh "$script"
done

echo "<<< Run all test success >>>"
