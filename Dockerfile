FROM alpine:latest
RUN apk add --no-cache python3 py3-pip bash
RUN pip install mysql-connector-python
RUN  mkdir /script
COPY db.py /script
