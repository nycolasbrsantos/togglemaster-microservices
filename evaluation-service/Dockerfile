# Estágio 1: Compilar

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download 
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/evaluation-service .

# Estágio 2: Execução

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/evaluation-service /evaluation-service
EXPOSE 8004
USER nonroot:nonroot
ENTRYPOINT [ "/evaluation-service" ]