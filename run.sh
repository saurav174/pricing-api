#!/bin/sh

set -eu

RATE_API_IMAGE="tripladev/rate-api:latest"
PRICING_API_IMAGE="pricing-api-local"

RATE_API_CONTAINER="rate-api"
PRICING_API_CONTAINER="pricing-api"

DOCKER_NETWORK="dynamic-pricing-network"

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$PROJECT_ROOT"

create_network() {
  if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    echo "Creating Docker network..."
    docker network create "$DOCKER_NETWORK" >/dev/null
  fi
}

wait_for_port() {
  port="$1"
  container="$2"
  attempts=30
  attempt=1

  echo "Waiting for $container to start on port $port..."

  while [ "$attempt" -le "$attempts" ]; do
    # Any HTTP response, including 404, means the server is reachable.
    if curl \
      --silent \
      --output /dev/null \
      --max-time 1 \
      "http://127.0.0.1:$port" 2>/dev/null; then
      echo "$container is running."
      return 0
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
      echo "$container stopped unexpectedly."
      docker logs "$container" || true
      exit 1
    fi

    sleep 1
    attempt=$((attempt + 1))
  done

  echo "$container did not start successfully."
  docker logs "$container" || true
  exit 1
}

start_rate_api() {
  create_network

  echo "Pulling Rate API image..."
  docker pull "$RATE_API_IMAGE"

  docker rm -f "$RATE_API_CONTAINER" >/dev/null 2>&1 || true

  echo "Starting Rate API..."
  docker run \
    --detach \
    --name "$RATE_API_CONTAINER" \
    --network "$DOCKER_NETWORK" \
    --publish 8080:8080 \
    "$RATE_API_IMAGE"

  wait_for_port 8080 "$RATE_API_CONTAINER"
}

build_pricing_api() {
  echo "Building the Rails Pricing API..."

  docker build \
    --tag "$PRICING_API_IMAGE" \
    .
}

start_pricing_api() {
  docker rm -f "$PRICING_API_CONTAINER" >/dev/null 2>&1 || true

  echo "Starting the Rails Pricing API..."

  docker run \
    --detach \
    --name "$PRICING_API_CONTAINER" \
    --network "$DOCKER_NETWORK" \
    --publish 3000:3000 \
    --volume "$PROJECT_ROOT:/rails" \
    --workdir /rails \
    --env RAILS_ENV=development \
    --env RATE_API_URL=http://rate-api:8080 \
    "$PRICING_API_IMAGE" \
    bundle exec rails server -b 0.0.0.0 -p 3000

  sleep 2

  if ! docker ps --format '{{.Names}}' | grep -qx "$PRICING_API_CONTAINER"; then
    echo "Pricing API failed to start:"
    docker logs "$PRICING_API_CONTAINER" || true
    exit 1
  fi

  wait_for_port 3000 "$PRICING_API_CONTAINER"

  echo
  echo "Both services are running:"
  echo "Rate API:    http://localhost:8080"
  echo "Pricing API: http://localhost:3000"
  echo
  echo "Run integration tests with: ./run.sh test"
}

start_services() {
  start_rate_api
  build_pricing_api
  start_pricing_api
}

run_integration_tests() {
  create_network

  if ! docker ps --format '{{.Names}}' | grep -qx "$RATE_API_CONTAINER"; then
    echo "Rate API is not running. Starting it first..."
    start_rate_api
  fi

  if ! docker image inspect "$PRICING_API_IMAGE" >/dev/null 2>&1; then
    build_pricing_api
  fi

  echo "Running Pricing API integration tests..."

  docker run \
    --rm \
    --network "$DOCKER_NETWORK" \
    --volume "$PROJECT_ROOT:/rails" \
    --workdir /rails \
    --env RAILS_ENV=test \
    --env RATE_API_URL=http://rate-api:8080 \
    "$PRICING_API_IMAGE" \
    bundle exec rails test test/controllers/pricing_controller_test.rb
}

case "${1:-start}" in
  start)
    start_services
    ;;
  test)
    run_integration_tests
    ;;
  *)
    echo "Usage: $0 {start|test}"
    exit 1
    ;;
esac