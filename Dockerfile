# Multi-stage build for smaller image size
# Stage 1: Build dependencies
FROM ruby:3.0-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    git \
    gmp-dev

WORKDIR /app

# Copy Gemfile and install gems
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs 4 --retry 3 && \
    # Remove unnecessary files to reduce size
    find vendor/bundle -name "*.c" -delete && \
    find vendor/bundle -name "*.o" -delete && \
    find vendor/bundle -name "*.h" -delete && \
    find vendor/bundle -name "*.md" -delete && \
    find vendor/bundle -name "*.txt" -delete && \
    find vendor/bundle -name "spec" -type d -exec rm -rf {} + 2>/dev/null || true && \
    find vendor/bundle -name "test" -type d -exec rm -rf {} + 2>/dev/null || true

# Stage 2: Runtime
FROM ruby:3.0-alpine

# Install only runtime dependencies
RUN apk add --no-cache \
    postgresql-libs \
    gmp \
    tzdata \
    wget \
    libc6-compat && \
    ln -s /lib/libc.so.6 /usr/lib/libresolv.so.2

WORKDIR /app

# Copy Gemfile files
COPY Gemfile Gemfile.lock ./

# Copy installed gems from builder
COPY --from=builder /app/vendor/bundle /app/vendor/bundle

# Setup bundle to use vendored gems
RUN bundle config set --local path 'vendor/bundle'

# Copy application code
COPY main.rb ./
COPY public/ ./

# Expose WebSocket port
EXPOSE 8080

# Environment variables (can be overridden)
ENV RELAY_NAME="Ruby Nostr Relay"
ENV RELAY_DESCRIPTION="A lightweight Nostr relay implementation in Ruby"
ENV RELAY_URL="ws://localhost:8080"
ENV DATABASE_URL=""

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080 || exit 1

# Run as non-root user
RUN addgroup -g 1000 nostr && \
    adduser -D -u 1000 -G nostr nostr && \
    chown -R nostr:nostr /app

USER nostr

# Run the relay
CMD ["bundle", "exec", "ruby", "main.rb"]
