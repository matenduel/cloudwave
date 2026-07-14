FROM golang:1.22-alpine AS build

WORKDIR /src
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -o /app .

FROM alpine:3.20
COPY --from=build /app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
