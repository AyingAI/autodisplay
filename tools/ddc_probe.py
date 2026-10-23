#!/usr/bin/env python3
"""Read-only Apple Silicon DDC/CI probe, using the macOS IOAVService API.

IOAVServiceWriteI2C sends read requests (Get VCP / Get Capabilities). This
program never sends Set VCP, reset, power, input selection, or save commands.
Transport signatures and Get VCP framing were checked against:
https://github.com/waydabber/AppleSiliconDDC
https://github.com/waydabber/m1ddc
"""

import argparse
import ctypes as C
import datetime
import functools
import json
import operator
import time


def xor(data, seed=0):
    return functools.reduce(operator.xor, data, seed)


class DDC:
    def __init__(self):
        self.io = C.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
        self.cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        bindings = {
            'IOServiceMatching': ([C.c_char_p], C.c_void_p),
            'IOServiceGetMatchingServices': ([C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32)], C.c_int32),
            'IOIteratorNext': ([C.c_uint32], C.c_uint32),
            'IOObjectRelease': ([C.c_uint32], C.c_int32),
            'IORegistryEntryCreateCFProperty': ([C.c_uint32, C.c_void_p, C.c_void_p, C.c_uint32], C.c_void_p),
            'IOAVServiceCreateWithService': ([C.c_void_p, C.c_uint32], C.c_void_p),
            'IOAVServiceWriteI2C': ([C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32], C.c_int32),
            'IOAVServiceReadI2C': ([C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32], C.c_int32),
        }
        for name, (args, result) in bindings.items():
            fn = getattr(self.io, name)
            fn.argtypes, fn.restype = args, result
        self.cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
        self.cf.CFStringCreateWithCString.restype = C.c_void_p
        self.cf.CFStringGetCString.argtypes = [C.c_void_p, C.c_char_p, C.c_long, C.c_uint32]
        self.cf.CFStringGetCString.restype = C.c_bool
        self.cf.CFRelease.argtypes = [C.c_void_p]

    def string_property(self, entry, name):
        key = self.cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
        value = self.io.IORegistryEntryCreateCFProperty(entry, key, None, 0)
        self.cf.CFRelease(key)
        if not value:
            return None
        try:
            out = C.create_string_buffer(1024)
            if self.cf.CFStringGetCString(value, out, len(out), 0x08000100):
                return out.value.decode()
        finally:
            self.cf.CFRelease(value)

    def exchange(self, service, payload, reply_size, checksum_seed):
        packet = [0x80 | len(payload), *payload]
        packet.append(xor(packet, checksum_seed))
        send = (C.c_ubyte * len(packet))(*packet)
        # Two identical requests and a 50 ms reply delay match established
        # Apple Silicon DDC implementations. These are queries only.
        for _ in range(2):
            time.sleep(0.02)
            err = self.io.IOAVServiceWriteI2C(service, 0x37, 0x51, send, len(send))
            if err:
                return {'status': 'transport_write_error', 'ioreturn': f'0x{err & 0xffffffff:08x}'}
        time.sleep(0.06)
        out = (C.c_ubyte * reply_size)()
        err = self.io.IOAVServiceReadI2C(service, 0x37, 0x51, out, len(out))
        if err:
            return {'status': 'transport_read_error', 'ioreturn': f'0x{err & 0xffffffff:08x}'}
        raw = bytes(out)
        if not any(raw):
            return {'status': 'empty_reply', 'raw': raw.hex()}
        size = (raw[1] & 0x7f) + 3
        frame = raw[:size]
        if size > len(raw) or raw[0] != 0x6e or xor(frame, 0x50) != 0:
            return {'status': 'invalid_reply', 'raw': raw.hex()}
        if size == 3:
            return {'status': 'null_reply', 'raw': frame.hex()}
        return {'status': 'ok', 'raw': frame.hex(), 'frame': frame}

    def get_vcp(self, service, code):
        attempts = []
        for seed in (0x6e ^ 0x51, 0x6e):
            for _ in range(2):
                result = self.exchange(service, [0x01, code], 11, seed)
                frame = result.pop('frame', None)
                if frame is not None and len(frame) == 11 and frame[2] == 0x02 and frame[4] == code:
                    return {
                        **result,
                        'status': 'ok' if frame[3] == 0 else 'unsupported',
                        'result_code': frame[3], 'type': frame[5],
                        'maximum': (frame[6] << 8) | frame[7],
                        'current': (frame[8] << 8) | frame[9],
                        'checksum_seed': f'0x{seed:02x}',
                    }
                attempts.append(result)
                time.sleep(0.08)
        return {'status': 'no_valid_vcp_reply', 'attempts': attempts}

    def capabilities(self, service):
        data = bytearray()
        for _ in range(128):
            offset = len(data)
            attempts = []
            frame = None
            for attempt in range(3):
                for seed in (0x6e ^ 0x51, 0x6e):
                    result = self.exchange(service, [0xf3, offset >> 8, offset & 0xff], 38, seed)
                    frame = result.pop('frame', None)
                    if frame is not None and len(frame) >= 6 and frame[2] == 0xe3:
                        returned_offset = (frame[3] << 8) | frame[4]
                        if returned_offset == offset:
                            break
                    frame = None
                    attempts.append(result)
                if frame is not None:
                    break
                time.sleep(0.1)
            if frame is None:
                return {'status': 'incomplete' if data else 'no_valid_capabilities_reply',
                        'text': data.decode('ascii', errors='replace'), 'attempts': attempts}
            chunk = frame[5:-1]
            if not chunk or 0 in chunk:
                data.extend(chunk.split(b'\0', 1)[0])
                return {'status': 'ok', 'text': data.decode('ascii', errors='replace')}
            data.extend(chunk)
        return {'status': 'size_limit', 'text': data.decode('ascii', errors='replace')}

    def probe(self, codes, read_capabilities):
        iterator = C.c_uint32()
        err = self.io.IOServiceGetMatchingServices(0, self.io.IOServiceMatching(b'DCPAVServiceProxy'), C.byref(iterator))
        report = {'timestamp': datetime.datetime.now().astimezone().isoformat(),
                  'read_only': True, 'matching_error': f'0x{err & 0xffffffff:08x}', 'services': []}
        if err:
            return report
        try:
            while entry := self.io.IOIteratorNext(iterator):
                try:
                    location = self.string_property(entry, 'Location')
                    if location != 'External':
                        continue
                    row = {'service_index': len(report['services']), 'location': location}
                    report['services'].append(row)
                    service = self.io.IOAVServiceCreateWithService(None, entry)
                    row['service_open'] = bool(service)
                    if not service:
                        continue
                    try:
                        row['vcp'] = {f'0x{code:02X}': self.get_vcp(service, code) for code in codes}
                        if read_capabilities:
                            row['capabilities'] = self.capabilities(service)
                    finally:
                        self.cf.CFRelease(service)
                finally:
                    self.io.IOObjectRelease(entry)
        finally:
            self.io.IOObjectRelease(iterator)
        return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feature', action='append', type=lambda value: int(value, 0), help='VCP code to read; may repeat')
    parser.add_argument('--capabilities', action='store_true')
    args = parser.parse_args()
    codes = args.feature if args.feature is not None else [0x10, 0x12, 0x14, 0xdc, 0xdb, 0xdf]
    if any(not 0 <= code <= 255 for code in codes):
        parser.error('VCP codes must be between 0 and 255')
    print(json.dumps(DDC().probe(codes, args.capabilities), ensure_ascii=False, indent=2))
