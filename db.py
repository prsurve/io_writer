import time

import mysql.connector
import os
import logging
import time

from datetime import datetime
import uuid
import secrets
import string
import socket
from functools import wraps

logging.basicConfig(format='%(asctime)s - %(threadName)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)

DB_USER = os.environ.get('MYSQL_DB_USER')
DB_PASSWORD = os.environ.get('MYSQL_DB_PASSWORD')
DB_HOST = os.environ.get('MYSQL_DB_HOST')
DB_NAME = "mydatabase"
DB_TABLE_NAME = "WORKLOAD"


def retry(ExceptionToCheck, tries=4, delay=3, backoff=2, logger=None):
    """Retry calling the decorated function using an exponential backoff.

    http://www.saltycrane.com/blog/2009/11/trying-out-retry-decorator-python/
    original from: http://wiki.python.org/moin/PythonDecoratorLibrary#Retry

    :param ExceptionToCheck: the exception to check. may be a tuple of
        exceptions to check
    :type ExceptionToCheck: Exception or tuple
    :param tries: number of times to try (not retry) before giving up
    :type tries: int
    :param delay: initial delay between retries in seconds
    :type delay: int
    :param backoff: backoff multiplier e.g. value of 2 will double the delay
        each retry
    :type backoff: int
    :param logger: logger to use. If None, print
    :type logger: logging.Logger instance
    """

    def deco_retry(f):

        @wraps(f)
        def f_retry(*args, **kwargs):
            mtries, mdelay = tries, delay
            while mtries > 1:
                try:
                    return f(*args, **kwargs)
                except ExceptionToCheck as e:
                    msg = "%s, Retrying in %d seconds..." % (str(e), mdelay)
                    if logger:
                        logger.warning(msg)

                    else:
                        print(msg)
                    time.sleep(mdelay)
                    mtries -= 1
                    mdelay *= backoff
            return f(*args, **kwargs)

        return f_retry  # true decorator

    return deco_retry


@retry(ExceptionToCheck=mysql.connector.errors.InterfaceError, tries=10, delay=5, logger=logging)
def create_db():
    mydb = mysql.connector.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
    )
    mycursor = mydb.cursor()

    mycursor.execute(f"CREATE DATABASE {DB_NAME}")
    logging.info("Creating Database")
    mycursor.fetchall()
    mydb.close()


def drop_table():
    sql = f"DROP TABLE {DB_TABLE_NAME}"

    mycursor.execute(sql)


def create_table():
    sql = f'''CREATE TABLE {DB_TABLE_NAME}(
       srno int NOT NULL AUTO_INCREMENT PRIMARY KEY,
       dt DATETIME,
       DATA LONGTEXT, host varchar(255)
    )'''

    mycursor.execute(sql)


def desc_table():
    sql = f"Desc {DB_TABLE_NAME}"

    mycursor.execute(sql)
    result = mycursor.fetchall();
    print(result)


def insert_data(sleep=5):
    while True:
        try:
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
            sql = f"INSERT INTO {DB_TABLE_NAME} (dt, DATA, host) VALUES (%s, %s, %s)"
            res = ''.join(secrets.choice(string.ascii_uppercase + string.digits)
                          for i in range(10))
            host_name = socket.gethostname()
            val = (now, res, host_name)
            logging.info(f"Data Written {now} {res} {host_name}")
            mycursor.execute(sql, val)
            mydb.commit()
            time.sleep(sleep)
        except mysql.connector.errors.OperationalError as e:
            logging.error(e)


def show_data():
    sql = f"SELECT * FROM {DB_TABLE_NAME}"
    mycursor.execute(sql)
    myresult = mycursor.fetchall()

    logging.info(myresult)


if __name__ == "__main__":

    try:
        create_db()
    except mysql.connector.errors.DatabaseError as e:
        logging.info("Database already exists")
    # drop_table()
    mydb = mysql.connector.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME
    )
    mycursor = mydb.cursor()

    try:
        create_table()
    except mysql.connector.errors.ProgrammingError as e:
        logging.info("Table already exists")

    # desc_table()
    logging.info("Writting Data")
    insert_data()
    # show_data()
