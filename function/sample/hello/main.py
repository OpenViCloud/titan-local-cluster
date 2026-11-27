import os


def handler(event, context):
    return {"statusCode": 200, "body": "hello kernel=%s" % os.uname().release}
