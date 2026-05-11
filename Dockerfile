FROM gotenberg/gotenberg:8.32.0

USER root

COPY ./fonts/* /usr/local/share/fonts/

USER gotenberg
