docker run -d --name ide -p 8444:8443 \
  -e PASSWORD=password -e DEFAULT_WORKSPACE=/code -e PUID=0 -e PGID=1000 -e TZ="Asia/Seoul" \
  -v ./src:/code -v /var/run/docker.sock:/var/run/docker.sock -v config:/config \
  linuxserver/code-server:4.90.3