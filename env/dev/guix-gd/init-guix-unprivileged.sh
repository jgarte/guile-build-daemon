# Load variables from 'config.scm' module
GUIX_GD_ROOT=$(guile -c "(display (@ (guix-gd config) guix-gd-root))")
GUIX_GD_USER=$(guile -c "(display (@ (guix-gd config) guix-gd-user))")

echo "------------------------------------------"
echo "Configuration for unprivileged dev guixdaemon:"
echo "  GUIX_GD_ROOT: $GUIX_GD_ROOT"
echo "  GUIX_GD_USER: $GUIX_GD_USER"
echo "------------------------------------------"

printf "Init directories, group/user(s) for unprivileged dev guixdaemon? [y/N]: "
read -r CONFIRM

case "$CONFIRM" in
    [yY][eE][sS]|[yY])
        echo "Proceeding with unprivileged dev guixdaemon initialization..."

        groupadd --system ${GUIX_GD_USER}
        useradd -g ${GUIX_GD_USER} -G ${GUIX_GD_USER}              \
                -d /var/empty -s $(which nologin)          \
                -c "Guix daemon privilege separation user" \
                --system ${GUIX_GD_USER}

        # populate new root
        mkdir -p "${GUIX_GD_ROOT}/gnu/store"
        mkdir -p "${GUIX_GD_ROOT}/var/guix/daemon-socket"
        mkdir -p "${GUIX_GD_ROOT}/var/log/guix"
        mkdir -p "${GUIX_GD_ROOT}/etc/guix"
        
        chown --recursive ${GUIX_GD_USER}:${GUIX_GD_USER} \
              "${GUIX_GD_ROOT}/gnu" \
              "${GUIX_GD_ROOT}/var" \
              "${GUIX_GD_ROOT}/etc"
        ;;
    *)
        echo "Aborting."
        exit 1
        ;;
esac
