docker exec -it ide /bin/bash

# Copy the script file from host to container
docker cp ./docker_install_script.sh ide:/docker_install_script.sh

# Execute the install script
docker exec ide /bin/bash /docker_install_script.sh

# Check docker version
docker exec ide docker --version