#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Regenerates Sources/SteamKit/Generated from Protos/.
# Protos are copied from https://github.com/SteamDatabase/Protobufs (steam/) at the commit in
# Protos/SOURCE_COMMIT. enums.proto is trimmed; see the note at its top.
# Requires protoc and protoc-gen-swift matching the swift-protobuf version in Package.swift
# (brew install protobuf swift-protobuf).
set -eu
cd "$(dirname "$0")/.."
rm -f Sources/SteamKit/Generated/*.pb.swift
protoc --proto_path=Protos \
  --swift_opt=Visibility=Public \
  --swift_out=Sources/SteamKit/Generated \
  Protos/*.proto
