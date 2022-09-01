FROM gotenberg/gotenberg:7

USER root

COPY ./fonts/* /usr/local/share/fonts/

USER gotenberg