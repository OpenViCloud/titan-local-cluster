# The sample function of runtimes-verify.sh for the python runtime. The three samples (python, node, go) answer alike.
import json
import os


def handler(event, context):
    if event["trigger"] == "cron":
        print("CRON-EVENT " + json.dumps(event), flush=True)
        if os.environ.get("SAMPLE_CRON") == "fail":
            raise RuntimeError("sample cron failure")
        return None
    if event["path"] == "/fail":
        raise RuntimeError("sample failure")
    try:
        open("/function/x", "w").close()
        fn_write = "ok"
    except OSError:
        fn_write = "denied"
    try:
        open("/tmp/x", "w").close()
        tmp_write = "ok"
    except OSError:
        tmp_write = "denied"
    body = f"hello python kernel={os.uname().release} uid={os.getuid()} fnwrite={fn_write} tmpwrite={tmp_write} path={event['path']} fn={context.function_id} version={context.version_id} left={context.get_remaining_time_in_millis()}"
    return {"statusCode": 201, "headers": {"x-runtime": "python"}, "body": body}
