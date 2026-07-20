# build
FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod ./
# resolve deps (go.sum generated during build; no vendored modules committed)
RUN go mod download all || true
COPY . .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/fss .

# runtime
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/fss /fss
USER nonroot:nonroot
ENTRYPOINT ["/fss"]
