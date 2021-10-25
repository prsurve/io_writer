FROM quay.io/aptible/alpine:3.12
RUN apk add --no-cache python3 py3-pip bash
RUN pip install mysql-connector-python
RUN  mkdir /script
COPY db.py /script
