FROM mcr.microsoft.com/devcontainers/dotnet:dev-7.0

# Битый/просроченный ключ репозитория Yarn ломает apt-get update
RUN rm -f /etc/apt/sources.list.d/yarn.list \
 && apt-get update \
 && rm -rf /var/lib/apt/lists/*