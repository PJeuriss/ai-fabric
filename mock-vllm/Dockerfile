FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/mock-vllm .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/mock-vllm /mock-vllm
USER nonroot:nonroot
EXPOSE 8000
ENTRYPOINT ["/mock-vllm"]
