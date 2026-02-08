FROM quay.io/ansible/awx:24.6.1

USER root

# Install receptor for AWX job mesh
ADD https://github.com/ansible/receptor/releases/download/v1.6.3/receptor_1.6.3_linux_amd64.tar.gz /tmp/receptor.tar.gz
RUN tar -xzf /tmp/receptor.tar.gz -C /usr/bin receptor && \
    chmod +x /usr/bin/receptor && \
    rm /tmp/receptor.tar.gz && \
    mkdir -p /etc/receptor /var/run/receptor && \
    chown 1000:0 /etc/receptor /var/run/receptor

# Install Docker CLI for Execution Environment container management
# AWX hardcodes "podman" as process_isolation_executable; symlink to docker
ADD https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz /tmp/docker.tgz
RUN tar -xzf /tmp/docker.tgz --strip-components=1 -C /usr/bin docker/docker && \
    chmod +x /usr/bin/docker && \
    ln -s /usr/bin/docker /usr/bin/podman && \
    rm /tmp/docker.tgz

# Shared directory for ansible-runner job data (Docker-in-Docker volume mounts)
RUN mkdir -p /tmp/awx-jobs && chown 1000:0 /tmp/awx-jobs

USER 1000
