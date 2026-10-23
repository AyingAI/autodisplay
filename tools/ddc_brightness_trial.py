#!/usr/bin/env python3
"""Temporarily set hardware brightness and restore the exact original value.

Only VCP 0x10 can be written. This does not claim to select an HDR preset.
The physical OSD label must be checked independently by the user.
"""

import argparse
import ctypes as C
import datetime
import json
from pathlib import Path
import signal
import time

from ddc_probe import DDC, xor


STOP = False
READ_CODES = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1a, 0x6c, 0x6e, 0x70, 0xdc]


def request_stop(signum, frame):
    global STOP
    STOP = True


def snapshot(ddc, service):
    return {f'0x{code:02X}': ddc.get_vcp(service, code) for code in READ_CODES}


def set_brightness(ddc, service, value):
    packet = [0x84, 0x03, 0x10, value >> 8, value & 0xff]
    packet.append(xor(packet, 0x6e ^ 0x51))
    data = (C.c_ubyte * len(packet))(*packet)
    for _ in range(2):
        time.sleep(0.05)
        error = ddc.io.IOAVServiceWriteI2C(service, 0x37, 0x51, data, len(data))
        if error:
            raise RuntimeError(f'Brightness write failed: 0x{error & 0xffffffff:08x}')
    time.sleep(0.3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--brightness', type=int, required=True)
    parser.add_argument('--hold-seconds', type=float, default=45)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.brightness <= 100 or not 0 <= args.hold_seconds <= 60:
        parser.error('Use brightness 0..100 and duration 0..60 seconds')
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, request_stop)
    ddc = DDC()
    iterator = C.c_uint32()
    error = ddc.io.IOServiceGetMatchingServices(0, ddc.io.IOServiceMatching(b'DCPAVServiceProxy'), C.byref(iterator))
    if error:
        raise RuntimeError(f'Cannot enumerate display services: {error}')
    entries = []
    service = None
    try:
        while entry := ddc.io.IOIteratorNext(iterator):
            if ddc.string_property(entry, 'Location') == 'External':
                entries.append(entry)
            else:
                ddc.io.IOObjectRelease(entry)
        if len(entries) != 1:
            raise RuntimeError('Exactly one external display service is required')
        service = ddc.io.IOAVServiceCreateWithService(None, entries[0])
        if not service:
            raise RuntimeError('Cannot open display service; no settings changed')
        baseline = snapshot(ddc, service)
        original = baseline['0x10']
        if original['status'] != 'ok' or args.brightness > original['maximum']:
            raise RuntimeError('Cannot establish original brightness or requested value is out of range')
        report = {'timestamp': datetime.datetime.now().astimezone().isoformat(),
                  'written_vcp': '0x10', 'trial_brightness': args.brightness, 'baseline': baseline}
        args.report.parent.mkdir(parents=True, exist_ok=True)

        def save():
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

        save()
        try:
            set_brightness(ddc, service, args.brightness)
            report['trial'] = snapshot(ddc, service)
            save()
            confirmed = report['trial']['0x10']
            if confirmed['status'] != 'ok' or confirmed['current'] != args.brightness:
                raise RuntimeError('Trial brightness was not confirmed by readback')
            print(json.dumps({'phase': 'trial', 'brightness': confirmed['current'],
                              'osd_label': 'requires_user_observation', 'automatic_restore_in_seconds': args.hold_seconds}), flush=True)
            deadline = time.monotonic() + args.hold_seconds
            while not STOP and time.monotonic() < deadline:
                time.sleep(0.1)
        finally:
            for attempt in range(3):
                try:
                    set_brightness(ddc, service, original['current'])
                except RuntimeError as error:
                    report['last_restore_error'] = str(error)
                    continue
                restored = ddc.get_vcp(service, 0x10)
                if restored['status'] == 'ok' and restored['current'] == original['current']:
                    break
            report['restored'] = snapshot(ddc, service)
            report['brightness_restored'] = report['restored']['0x10'].get('current') == original['current']
            report['differences_after_restore'] = {
                code: {'before': before.get('current'), 'after': report['restored'][code].get('current')}
                for code, before in baseline.items()
                if before['status'] == 'ok' and
                (report['restored'][code]['status'] != 'ok' or before.get('current') != report['restored'][code].get('current'))
            }
            save()
            print(json.dumps({'phase': 'restored', 'brightness_restored': report['brightness_restored'],
                              'differences': report['differences_after_restore']}), flush=True)
    finally:
        if service:
            ddc.cf.CFRelease(service)
        for entry in entries:
            ddc.io.IOObjectRelease(entry)
        ddc.io.IOObjectRelease(iterator)


if __name__ == '__main__':
    main()
