#!/usr/bin/env bash
CONFIG_FILE="huly_v7.conf"

# Parse command line arguments
RESET_VOLUMES=false
SECRET=false
QUICK=false
DB_ARG=""

while [ $# -gt 0 ]; do
    case $1 in
        --secret)
            SECRET=true
            ;;
        --reset-volumes)
            RESET_VOLUMES=true
            ;;
        --quick)
            QUICK=true
            ;;
        --db=*)
            DB_ARG="${1#--db=}"
            ;;
        --db)
            DB_ARG="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --secret         Generate a new secret key"
            echo "  --reset-volumes  Reset all volume paths to default Docker named volumes"
            echo "  --quick          Quick setup with defaults (localhost:8087, no SSL, auto-start)"
            echo "  --db TYPE        Database for a new install: 'cockroach' (default) or 'postgres'."
            echo "                   An existing install keeps its database; switching does not migrate data."
            echo "  --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

case "$DB_ARG" in
    ""|cockroach|postgres) ;;
    *)
        echo "Unknown database type: '$DB_ARG' (expected 'cockroach' or 'postgres')"
        exit 1
        ;;
esac

if [ "$RESET_VOLUMES" == true ]; then
    echo -e "\033[33m--reset-volumes flag detected: Resetting all volume paths to default Docker named volumes.\033[0m"
    sed -i \
        -e '/^VOLUME_ELASTIC_PATH=/s|=.*|=|' \
        -e '/^VOLUME_FILES_PATH=/s|=.*|=|' \
        -e '/^VOLUME_CR_DATA_PATH=/s|=.*|=|' \
        -e '/^VOLUME_CR_CERTS_PATH=/s|=.*|=|' \
        -e '/^VOLUME_PG_DATA_PATH=/s|=.*|=|' \
        -e '/^VOLUME_REDPANDA_PATH=/s|=.*|=|' \
        "$CONFIG_FILE"
    exit 0
fi

# Database type. An existing install keeps the database it was created with: a config
# written before DB_TYPE existed is a CockroachDB install. Switching would start the
# platform on an empty database, so it is refused rather than silently done.
EXISTING_DB_TYPE=""
if [ -f "$CONFIG_FILE" ]; then
    EXISTING_DB_TYPE=$(sed -n 's/^DB_TYPE=//p' "$CONFIG_FILE" | tail -1)
    EXISTING_DB_TYPE="${EXISTING_DB_TYPE:-cockroach}"
fi
if [[ -n "$DB_ARG" && -n "$EXISTING_DB_TYPE" && "$DB_ARG" != "$EXISTING_DB_TYPE" ]]; then
    echo -e "\033[1;31mThis install uses '$EXISTING_DB_TYPE' (see DB_TYPE in $CONFIG_FILE); --db $DB_ARG was requested.\033[0m"
    echo "Changing the database type does not migrate data: the platform would start on an empty database."
    echo "To set up a fresh install with '$DB_ARG' instead, back up and remove $CONFIG_FILE and the old data volumes first."
    exit 1
fi
DB_TYPE="${DB_ARG:-$EXISTING_DB_TYPE}"

# Quick mode: use all defaults, skip prompts
if [ "$QUICK" == true ]; then
    DB_TYPE="${DB_TYPE:-cockroach}"
    echo -e "\033[1;34m🚀 Quick setup mode - using defaults for fast verification\033[0m"
    _HOST_ADDRESS="localhost:8087"
    _HTTP_PORT="8087"
    _SECURE=""
    _VOLUME_ELASTIC_PATH=""
    _VOLUME_FILES_PATH=""
    _VOLUME_CR_DATA_PATH=""
    _VOLUME_CR_CERTS_PATH=""
    _VOLUME_PG_DATA_PATH=""
    _VOLUME_REDPANDA_PATH=""
else

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

while true; do
    if [[ -n "$HOST_ADDRESS" ]]; then
        prompt_type="current"
        prompt_value="${HOST_ADDRESS}"
    else
        prompt_type="default"
        prompt_value="localhost"
    fi
    read -p "Enter the host address (domain name or IP) [${prompt_type}: ${prompt_value}]: " input
    _HOST_ADDRESS="${input:-${HOST_ADDRESS:-localhost}}"
    break
done

while true; do
    if [[ -n "$HTTP_PORT" ]]; then
        prompt_type="current"
        prompt_value="${HTTP_PORT}"
    else
        prompt_type="default"
        prompt_value="80"
    fi
    read -p "Enter the port for HTTP [${prompt_type}: ${prompt_value}]: " input
    _HTTP_PORT="${input:-${HTTP_PORT:-80}}"
    if [[ "$_HTTP_PORT" =~ ^[0-9]+$ && "$_HTTP_PORT" -ge 1 && "$_HTTP_PORT" -le 65535 ]]; then
        break
    else
        echo "Invalid port. Please enter a number between 1 and 65535."
    fi
done

echo "$_HOST_ADDRESS $HOST_ADDRESS $_HTTP_PORT $HTTP_PORT"

if [[ "$_HOST_ADDRESS" == "localhost" || "$_HOST_ADDRESS" == "127.0.0.1" || "$_HOST_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:?$ ]]; then
    _HOST_ADDRESS="${_HOST_ADDRESS%:}:${_HTTP_PORT}"
    SECURE=""
else
    while true; do
        if [[ -n "$SECURE" ]]; then
            prompt_type="current"
            prompt_value="Yes"
        else
            prompt_type="default"
            prompt_value="No"
        fi
        read -p "Will you serve the platform over SSL? (y/n) [${prompt_type}: ${prompt_value}]: " input
        case "${input}" in
            [Yy]* )
                _SECURE="true"; break;;
            [Nn]* )
                _SECURE=""; break;;
            "" )
                _SECURE="${SECURE:+true}"; break;;
            * )
                echo "Invalid input. Please enter Y or N.";;
        esac
    done
fi

# Database selection (new installs only; an existing install keeps its database)
if [[ -z "$DB_TYPE" ]]; then
    while true; do
        read -p "Which database should the platform use? (cockroach/postgres) [default: cockroach]: " input
        case "${input}" in
            ""|[Cc]ockroach|[Cc]r ) DB_TYPE="cockroach"; break;;
            [Pp]ostgres|[Pp]ostgresql|[Pp]g ) DB_TYPE="postgres"; break;;
            * ) echo "Invalid input. Please enter 'cockroach' or 'postgres'.";;
        esac
    done
else
    echo -e "Database: \033[1;32m${DB_TYPE}\033[0m"
fi

# Volume path configuration
echo -e "\n\033[1;34mDocker Volume Configuration:\033[0m"

    echo "You can specify custom paths for persistent data storage, or leave empty to use default Docker named volumes."
    echo -e "\033[33mTip: To revert from custom paths to default volumes, enter 'default' or just press Enter when prompted.\033[0m"

    # Elasticsearch volume configuration
    if [[ -n "$VOLUME_ELASTIC_PATH" ]]; then
        current_elastic="custom: $VOLUME_ELASTIC_PATH"
    else
        current_elastic="default Docker volume"
    fi
    read -p "Enter custom path for Elasticsearch volume [current: ${current_elastic}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_ELASTIC_PATH=""
    else
        _VOLUME_ELASTIC_PATH="${input:-${VOLUME_ELASTIC_PATH}}"
    fi

    # Files volume configuration
    if [[ -n "$VOLUME_FILES_PATH" ]]; then
        current_files="custom: $VOLUME_FILES_PATH"
    else
        current_files="default Docker volume"
    fi
    read -p "Enter custom path for files volume [current: ${current_files}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_FILES_PATH=""
    else
        _VOLUME_FILES_PATH="${input:-${VOLUME_FILES_PATH}}"
    fi

    if [[ "$DB_TYPE" == "cockroach" ]]; then
        # Cockroach data volume configuration
        if [[ -n "$VOLUME_CR_DATA_PATH" ]]; then
            current_cr_data="custom: $VOLUME_CR_DATA_PATH"
        else
            current_cr_data="default Docker volume"
        fi
        read -p "Enter custom path for CR data volume [current: ${current_cr_data}]: " input
        if [[ "$input" == "default" ]]; then
            _VOLUME_CR_DATA_PATH=""
        else
            _VOLUME_CR_DATA_PATH="${input:-${VOLUME_CR_DATA_PATH}}"
        fi

        # Cockroach certs volume configuration
        if [[ -n "$VOLUME_CR_CERTS_PATH" ]]; then
            current_cr_certs="custom: $VOLUME_CR_CERTS_PATH"
        else
            current_cr_certs="default Docker volume"
        fi
        read -p "Enter custom path for CR certs volume [current: ${current_cr_certs}]: " input
        if [[ "$input" == "default" ]]; then
            _VOLUME_CR_CERTS_PATH=""
        else
            _VOLUME_CR_CERTS_PATH="${input:-${VOLUME_CR_CERTS_PATH}}"
        fi
    else
        # PostgreSQL data volume configuration
        if [[ -n "$VOLUME_PG_DATA_PATH" ]]; then
            current_pg_data="custom: $VOLUME_PG_DATA_PATH"
        else
            current_pg_data="default Docker volume"
        fi
        read -p "Enter custom path for PostgreSQL data volume [current: ${current_pg_data}]: " input
        if [[ "$input" == "default" ]]; then
            _VOLUME_PG_DATA_PATH=""
        else
            _VOLUME_PG_DATA_PATH="${input:-${VOLUME_PG_DATA_PATH}}"
        fi
    fi

    # Redpanda volume configuration
    if [[ -n "$VOLUME_REDPANDA_PATH" ]]; then
        current_redpanda="custom: $VOLUME_REDPANDA_PATH"
    else
        current_redpanda="default Docker volume"
    fi
    read -p "Enter custom path for Redpanda volume [current: ${current_redpanda}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_REDPANDA_PATH=""
    else
        _VOLUME_REDPANDA_PATH="${input:-${VOLUME_REDPANDA_PATH}}"
    fi

fi # End of non-quick mode

if [ ! -f .huly.secret ] || [ "$SECRET" == true ]; then
  openssl rand -hex 32 > .huly.secret
  echo "Secret generated and stored in .huly.secret"
else
  echo -e "\033[33m.huly.secret already exists, not overwriting."
  echo "Run this script with --secret to generate a new secret."
fi

if [ "$DB_TYPE" == "cockroach" ] && [ ! -f .cr.secret ]; then
  openssl rand -hex 32 > .cr.secret
  echo "Secret generated and stored in .cr.secret"
fi

if [ "$DB_TYPE" == "postgres" ] && [ ! -f .pg.secret ]; then
  openssl rand -hex 32 > .pg.secret
  echo "Secret generated and stored in .pg.secret"
fi

if [ ! -f .rp.secret ]; then
  openssl rand -hex 32 > .rp.secret
  echo "Secret generated and stored in .rp.secret"
fi

export HOST_ADDRESS=$_HOST_ADDRESS
export SECURE=$_SECURE
export HTTP_PORT=$_HTTP_PORT
export HTTP_BIND=$HTTP_BIND
export TITLE=${TITLE:-Platform}
export DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE:-en}
export LAST_NAME_FIRST=${LAST_NAME_FIRST:-true}
export DB_TYPE=$DB_TYPE
export CR_DATABASE=${CR_DATABASE:-defaultdb}
export CR_USERNAME=${CR_USERNAME:-selfhost}
export PG_DATABASE=${PG_DATABASE:-huly}
export PG_USERNAME=${PG_USERNAME:-selfhost}
export REDPANDA_ADMIN_USER=${REDPANDA_ADMIN_USER:-superadmin}
export VOLUME_ELASTIC_PATH=$_VOLUME_ELASTIC_PATH
export VOLUME_FILES_PATH=$_VOLUME_FILES_PATH
export VOLUME_CR_DATA_PATH=$_VOLUME_CR_DATA_PATH
export VOLUME_CR_CERTS_PATH=$_VOLUME_CR_CERTS_PATH
export VOLUME_PG_DATA_PATH=$_VOLUME_PG_DATA_PATH
export VOLUME_REDPANDA_PATH=$_VOLUME_REDPANDA_PATH
export HULY_SECRET=$(cat .huly.secret)
[ "$DB_TYPE" == "cockroach" ] && export COCKROACH_SECRET=$(cat .cr.secret)
[ "$DB_TYPE" == "postgres" ] && export PG_SECRET=$(cat .pg.secret)
export REDPANDA_SECRET=$(cat .rp.secret)

envsubst < .template.huly.conf > $CONFIG_FILE
envsubst < ".template.db-${DB_TYPE}.conf" >> $CONFIG_FILE

source "$CONFIG_FILE"

echo -e "\n\033[1;34mConfiguration Summary:\033[0m"
echo -e "Host Address: \033[1;32m$_HOST_ADDRESS\033[0m"
echo -e "HTTP Port: \033[1;32m$_HTTP_PORT\033[0m"
if [[ -n "$SECURE" ]]; then
    echo -e "SSL Enabled: \033[1;32mYes\033[0m"
else
    echo -e "SSL Enabled: \033[1;31mNo\033[0m"
fi
echo -e "Elasticsearch Volume: \033[1;32m${_VOLUME_ELASTIC_PATH:-Docker named volume}\033[0m"
echo -e "Files Volume: \033[1;32m${_VOLUME_FILES_PATH:-Docker named volume}\033[0m"
echo -e "Database: \033[1;32m$DB_TYPE\033[0m"
if [[ "$DB_TYPE" == "cockroach" ]]; then
    echo -e "CockroachDB Volume: \033[1;32m${_VOLUME_CR_DATA_PATH:-Docker named volume}\033[0m"
    echo -e "CockroachDB Certs Volume: \033[1;32m${_VOLUME_CR_CERTS_PATH:-Docker named volume}\033[0m"
else
    echo -e "PostgreSQL Volume: \033[1;32m${_VOLUME_PG_DATA_PATH:-Docker named volume}\033[0m"
fi
echo -e "Redpanda Volume: \033[1;32m${_VOLUME_REDPANDA_PATH:-Docker named volume}\033[0m"

# compose.postgres.yml uses the !override tag, added in Docker Compose v2.24.4.
if [[ "$DB_TYPE" == "postgres" ]]; then
    compose_version=$(docker compose version --short 2>/dev/null | sed 's/^v//')
    if [[ -n "$compose_version" ]] && \
       [[ "$(printf '%s\n' 2.24.4 "$compose_version" | sort -V | head -1)" != "2.24.4" ]]; then
        echo -e "\033[1;31mDocker Compose $compose_version is too old for the PostgreSQL setup (needs 2.24.4+).\033[0m"
        echo "Update Docker (https://docs.docker.com/engine/install/) and run this script again."
        exit 1
    fi
fi

compose_failed() {
    echo -e "\033[1;31m'docker compose up -d' failed.\033[0m"
    echo "If the error mentions 'gzip: invalid header' or another download error, an image layer"
    echo "was corrupted in transit. Run 'docker compose pull' again, then 'docker compose up -d'."
    exit 1
}

if [ "$QUICK" == true ]; then
    echo -e "\033[1;32mRunning 'docker compose up -d' now...\033[0m"
    docker compose up -d || compose_failed
else
    read -p "Do you want to run 'docker compose up -d' now to start the platform? (Y/n): " RUN_DOCKER
    case "${RUN_DOCKER:-Y}" in
        [Yy]* )
             echo -e "\033[1;32mRunning 'docker compose up -d' now...\033[0m"
             docker compose up -d || compose_failed
             ;;
        [Nn]* )
            echo "You can run 'docker compose up -d' later to start the platform."
            ;;
    esac
fi

echo -e "\033[1;32mSetup is complete!\n Generating nginx.conf...\033[0m"
./nginx.sh

if [ "$QUICK" == true ]; then
    echo ""
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;32m✅ Quick setup complete!\033[0m"
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo ""
    echo -e "🌐 Access the platform at: \033[1;36mhttp://localhost:8087\033[0m"
    echo ""
    echo -e "⏳ Wait ~60 seconds for all services to initialize..."
    echo -e "📊 Check status with: \033[1;33mdocker compose ps\033[0m"
    echo -e "📋 View logs with:   \033[1;33mdocker compose logs -f\033[0m"
    echo ""
fi
