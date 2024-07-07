FROM amazon/aws-cli:2.17.9 AS aws

FROM linuxserver/code-server:4.90.3

# ENV for Code-server (VSCode)
ENV TZ="Asia/Seoul"
ENV PUID=1000
ENV PGID=1000

# Update & Install the packages
RUN apt-get update && apt-get -y upgrade

RUN apt install -y ca-certificates curl gnupg software-properties-common wget unzip apt-transport-https

# Install AWS CLI from `amazon/aws-cli:2.17.9` image
COPY --from=aws /usr/local/aws-cli/v2 /usr/local/aws-cli/v2
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer

