# Estágio 1: Compilar

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download 
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/auth-service .

# Estágio 2: Execução

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/auth-service /auth-service
EXPOSE 8001
USER nonroot:nonroot
ENTRYPOINT [ "/auth-service" ]