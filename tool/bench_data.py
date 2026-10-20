# Erzeugt realistische Testdaten: großes Xtream-Portal + großes XMLTV.
import json, random, datetime, sys, os
random.seed(1)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
N_CH = 12000      # Sender (große Portale haben 10–30 Tsd.)
N_EPG_CH = 2500   # Sender mit EPG
streams = [{"num": i+1, "name": f"DE| Sender {i} HD", "stream_type": "live", "stream_id": 100000+i,
            "stream_icon": f"http://logos.example/{i}.png", "epg_channel_id": f"ch{i}.de" if i < N_EPG_CH else "",
            "added": "1700000000", "category_id": str(i % 180), "custom_sid": "", "tv_archive": i % 3 == 0 and 1 or 0,
            "direct_source": "", "tv_archive_duration": 7} for i in range(N_CH)]
json.dump(streams, open(f"{out}/live_streams.json", "w"))
now = datetime.datetime.now(datetime.timezone.utc).replace(minute=0, second=0, microsecond=0)
start = now - datetime.timedelta(days=7)
with open(f"{out}/epg.xml", "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
    for c in range(N_EPG_CH + 1500):  # 1500 Sender im EPG, die es im Portal nicht gibt
        f.write(f'<channel id="ch{c}.de"><display-name>Sender {c}</display-name></channel>\n')
    for c in range(N_EPG_CH + 1500):
        t = start
        end = now + datetime.timedelta(days=3)
        while t < end:
            d = datetime.timedelta(minutes=random.choice([30, 45, 60, 90]))
            fmt = lambda x: x.strftime("%Y%m%d%H%M%S +0000")
            f.write(f'<programme start="{fmt(t)}" stop="{fmt(t+d)}" channel="ch{c}.de"><title lang="de">Sendung {random.randint(1,999)}</title>'
                    f'<desc lang="de">Beschreibung der Sendung mit etwas Text, damit es realistisch groß wird.</desc><category lang="de">Unterhaltung</category></programme>\n')
            t += d
    f.write('</tv>\n')
print("live_streams.json", os.path.getsize(f"{out}/live_streams.json")//1024//1024, "MB")
print("epg.xml", os.path.getsize(f"{out}/epg.xml")//1024//1024, "MB")
