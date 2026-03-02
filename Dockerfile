FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY build/minilb /minilb

EXPOSE 8080
ENTRYPOINT ["/minilb"]
