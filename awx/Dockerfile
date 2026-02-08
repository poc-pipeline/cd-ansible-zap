FROM quay.io/ansible/awx:24.6.1

USER root

ADD https://github.com/ansible/receptor/releases/download/v1.6.3/receptor_1.6.3_linux_amd64.tar.gz /tmp/receptor.tar.gz
RUN tar -xzf /tmp/receptor.tar.gz -C /usr/bin receptor && \
    chmod +x /usr/bin/receptor && \
    rm /tmp/receptor.tar.gz && \
    mkdir -p /etc/receptor /var/run/receptor && \
    chown 1000:0 /etc/receptor /var/run/receptor

USER 1000
