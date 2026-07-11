#!/usr/bin/env bash
# Generates Dart gRPC bindings from proto/ into lib/gen/.
# Requires: protoc, dart pub global activate protoc_plugin
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

wkt_include=/usr/include
if [[ ! -f "$wkt_include/google/protobuf/empty.proto" ]]; then
  echo "google well-known protos not found under $wkt_include" >&2
  exit 1
fi

rm -rf lib/gen
mkdir -p lib/gen

protoc \
  -I ../proto \
  -I "$wkt_include" \
  --dart_out=grpc:lib/gen \
  ../proto/agent.proto \
  "$wkt_include/google/protobuf/empty.proto" \
  "$wkt_include/google/protobuf/timestamp.proto"

echo "Generated $(find lib/gen -name '*.dart' | wc -l) Dart files"
