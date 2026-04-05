echo "------------------------------------------"
echo "Configuration for dev guixdaemon as root:"
echo "  GUIX_GD_ROOT: $GUIX_GD_ROOT"
echo "  GUIX_GD_GROUP: $GUIX_GD_GROUP "
echo "------------------------------------------"

printf "Init directories, group/user(s) for dev guixdaemon as root? [y/N]: "
read -r CONFIRM

case "$CONFIRM" in
    [yY][eE][sS]|[yY])
        echo "Proceeding with dev guixdaemon initialization as root..."

        # make users
        groupadd --system ${GUIX_GD_GROUP}
        for i in $(seq -w 1 10); do
            useradd -g ${GUIX_GD_GROUP} -G ${GUIX_GD_GROUP} \
                    -d /var/empty -s $(which nologin) \
                    -c "Guix guile build daemon user $i" --system \
                    ${GUIX_GD_GROUP}-$i
        done

        # populate new root
        mkdir -p "${GUIX_GD_ROOT}/gnu/store"
        mkdir -p "${GUIX_GD_ROOT}/etc"
        # sudo mkdir -p "${GUIX_GD_ROOT}/var/guix/daemon-socket"  # created at first daemon run
        ;;
    *)
        echo "Aborting."
        exit 1
        ;;
esac
