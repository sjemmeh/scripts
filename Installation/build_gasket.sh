# Gasket install for ubuntu
apt-get update
apt-get install -q -y --no-install-recommends git curl devscripts dkms dh-dkms build-essential debhelper
mkdir build && cd build
git clone https://github.com/google/gasket-driver.git
cd gasket-driver && curl -L https://github.com/heitbaum/gasket-driver/commit/4b2a1464f3b619daaf0f6c664c954a42c4b7ce00.patch | git apply -v
curl -L https://github.com/sethyx/gasket-driver/commit/2b808eb8a0e313ef390bd26f64d2a0413a1b1394.patch | git apply -v
debuild -us -uc -tc -b
