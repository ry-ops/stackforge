FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o sf-api .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/sf-api /usr/local/bin/sf-api
USER 65534:65534
ENTRYPOINT ["sf-api"]
