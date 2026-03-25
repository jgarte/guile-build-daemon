# Load 'api-key' from 'config.scm'
GUIX-GD-ROOT=$(guile -l config.scm -c '(display guix-gd-root)')
GUIX-GD-GROUP=$(guile -l config.scm -c '(display guix-gd-group)')

# make users
sudo groupadd --system ${GUIX-GD-GROUP}
for i in $(seq -w 1 10); do
    sudo useradd -g ${GUIX-GD-GROUP} -G ${GUIX-GD-GROUP} \
         -d /var/empty -s $(which nologin) \
         -c "Guix guile build daemon user $i" --system \
         ${GUIX-GD-GROUP}-$i
done

# populate new root
sudo mkdir -p "${GUIX-GD-ROOT}/gnu/store"
# sudo mkdir -p "${GUIX-GD-ROOT}/var/guix/daemon-socket"  # created at first daemon run
sudo mkdir -p "${GUIX-GD-ROOT}/etc"
sudo mkdir -p "${GUIX-GD-ROOT}/let"

