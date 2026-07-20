# Builds a custom llm-d EPP that embeds the fabric scorer.
# NOTE: recent gateway-api-inference-extension releases (>= v1.5.0) require Go 1.25.
FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
COPY . .
# Resolve GIE at the version present in go.mod (uncomment the require + set it to
# match GIE_VERSION), then build with the `gie` tag to include the plugin glue.
# `go mod tidy` here pulls GIE (the gie-tagged files reference it).
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -tags gie -o /out/epp ./cmd/epp

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/epp /epp
USER nonroot:nonroot
ENTRYPOINT ["/epp"]
