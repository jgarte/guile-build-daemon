echo "------------------------------------------"
echo "Configuration for dev guixdaemon as root:"
echo "  GUIX_GD_GROUP: $GUIX_GD_GROUP "
echo "------------------------------------------"

printf "Init group/user(s) for dev guixdaemon as root? [y/N]: "
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
        ;;
    *)
        echo "Aborting."
        exit 1
        ;;
esac
