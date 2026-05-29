#!/usr/bin/env python3
"""Publica mensagens MQTT a 100 msg/s simulando o GT100 MMW03."""

import json
import os
import random
import signal
import sys
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("paho-mqtt não encontrado. Instale com: pip install paho-mqtt")
    sys.exit(1)


def read_env(path=".env"):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def make_payload():
    l1v = round(random.uniform(218, 222), 1)
    l2v = round(random.uniform(218, 222), 1)
    l3v = round(random.uniform(218, 222), 1)
    l1i = round(random.uniform(3.0, 4.5), 2)
    l2i = round(random.uniform(3.0, 4.5), 2)
    l3i = round(random.uniform(3.0, 4.5), 2)
    l1p = round(l1v * l1i * 0.98, 1)
    l2p = round(l2v * l2i * 0.98, 1)
    l3p = round(l3v * l3i * 0.98, 1)
    ptot = round(l1p + l2p + l3p, 1)
    return {
        "data": {
            "v_med":    round((l1v + l2v + l3v) / 3, 1),
            "i_tot":    round(l1i + l2i + l3i, 2),
            "p_tot":    ptot,
            "q_tot":    round(ptot * 0.2, 1),
            "s_tot":    round(ptot * 1.02, 1),
            "fp_med":   0.98,
            "thdv_tot": round(random.uniform(1.5, 3.5), 1),
            "thdi_tot": round(random.uniform(2.0, 5.0), 1),
            "l1_v": l1v, "l1_i": l1i, "l1_p": l1p, "l1_f": 60.0,
            "l2_v": l2v, "l2_i": l2i, "l2_p": l2p, "l2_f": 60.0,
            "l3_v": l3v, "l3_i": l3i, "l3_p": l3p, "l3_f": 60.0,
        }
    }


def main():
    env = read_env()
    host  = env.get("MQTT_HOST", "localhost")
    port  = int(env.get("MQTT_PORT", 1883))
    user  = env.get("EMQX_MQTT_USER", "gt100-validacao")
    passw = env.get("EMQX_MQTT_PASSWORD", "")
    topic = env.get("MQTT_TOPIC", "wnology/gt100-poc-01/state")
    rate  = int(env.get("MQTT_RATE", 100))

    client = mqtt.Client()
    client.username_pw_set(user, passw)

    connected = False

    def on_connect(c, userdata, flags, rc):
        nonlocal connected
        if rc == 0:
            connected = True
            print(f"Conectado ao broker {host}:{port}")
        else:
            print(f"Falha na conexão: rc={rc}")
            sys.exit(1)

    client.on_connect = on_connect
    client.connect(host, port, keepalive=60)
    client.loop_start()

    deadline = time.monotonic()
    while not connected:
        time.sleep(0.05)

    interval = 1.0 / rate
    count = 0
    t_start = time.monotonic()

    def handle_sigint(sig, frame):
        elapsed = time.monotonic() - t_start
        actual_rate = count / elapsed if elapsed > 0 else 0
        print(f"\nEnviadas {count} mensagens em {elapsed:.1f}s ({actual_rate:.1f} msg/s)")
        client.loop_stop()
        client.disconnect()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_sigint)

    print(f"Publicando em '{topic}' a {rate} msg/s — Ctrl+C para parar")

    while True:
        payload = json.dumps(make_payload())
        client.publish(topic, payload, qos=0)
        count += 1

        if count % rate == 0:
            elapsed = time.monotonic() - t_start
            print(f"{time.strftime('%H:%M:%S')} — {count} msgs ({count/elapsed:.1f} msg/s)")

        deadline += interval
        sleep_time = deadline - time.monotonic()
        if sleep_time > 0:
            time.sleep(sleep_time)


if __name__ == "__main__":
    main()
