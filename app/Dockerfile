FROM golang:1.27.0-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY app/ ./app/
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-X main.version=${VERSION}" -o /out/demo-api ./app

FROM alpine:3.24.0
COPY --from=build /out/demo-api /usr/local/bin/demo-api
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/demo-api"]
