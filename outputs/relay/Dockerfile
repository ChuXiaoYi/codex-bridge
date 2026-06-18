FROM node:22-alpine

WORKDIR /app
COPY relay.mjs start-relay.sh ./
RUN chmod +x /app/start-relay.sh

ENV RELAY_HOST=0.0.0.0
ENV RELAY_PORT=8788
EXPOSE 8788

USER node
CMD ["/app/start-relay.sh"]
