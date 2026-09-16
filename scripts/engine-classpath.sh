#!/bin/sh
# Emit a classpath for running Frostlake's DatabaseHttpServer from the local
# Maven repository — the engine jar plus its exact third-party dependencies.
# Usage: engine-classpath.sh [engine-version]   (default 0.1.0-SNAPSHOT)
set -eu

VERSION="${1:-0.1.0-SNAPSHOT}"
M2="${M2_REPO:-$HOME/.m2/repository}"

JARS="
dev/frostlake/frostlake-db/$VERSION/frostlake-db-$VERSION.jar
tools/jackson/core/jackson-databind/3.2.1/jackson-databind-3.2.1.jar
tools/jackson/core/jackson-core/3.2.1/jackson-core-3.2.1.jar
com/fasterxml/jackson/core/jackson-annotations/2.22/jackson-annotations-2.22.jar
org/antlr/antlr4-runtime/4.13.2/antlr4-runtime-4.13.2.jar
org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar
org/slf4j/slf4j-simple/2.0.17/slf4j-simple-2.0.17.jar
io/airlift/aircompressor/2.0.3/aircompressor-2.0.3.jar
org/jline/jline/3.30.9/jline-3.30.9.jar
org/graalvm/polyglot/polyglot/25.0.2/polyglot-25.0.2.jar
"

CP=""
for jar in $JARS; do
    path="$M2/$jar"
    if [ ! -f "$path" ]; then
        echo "missing: $path" >&2
        exit 1
    fi
    CP="${CP:+$CP:}$path"
done
printf '%s\n' "$CP"
