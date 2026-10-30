# The publish-bugreport workflow builds the static binary; the image only
# copies it. Runs as root on purpose: the reports hostPath on the server
# already holds root-owned report directories from the `go run` era.
FROM gcr.io/distroless/static-debian12
COPY bugreport /bugreport
ENTRYPOINT ["/bugreport"]
