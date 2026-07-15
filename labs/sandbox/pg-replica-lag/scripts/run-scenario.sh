#!/bin/sh
set -eu
docker compose up -d --build
docker compose --profile load run --rm k6
