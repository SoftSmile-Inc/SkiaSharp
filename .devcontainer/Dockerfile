FROM mcr.microsoft.com/devcontainers/dotnet:dev-7.0

# Outdated Yarn repository key in the base image breaks apt-get update
# (NO_PUBKEY 62D54FD4003F6525). This must be removed before dev container
# features (e.g. docker-in-docker) run their own apt-get update during the
# image build - onCreateCommand runs too late to fix this, since it only
# executes after features have already been installed.
RUN rm -f /etc/apt/sources.list.d/yarn.list && apt-get update
