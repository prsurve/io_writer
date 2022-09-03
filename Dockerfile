FROM quay.io/aptible/alpine:latest
RUN apk add --no-cache python3 py3-pip bash
RUN pip install mysql-connector-python Faker
RUN  mkdir /script
COPY db.py /script
