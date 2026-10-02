// ============================================================================
// Modbus RTU yardimcilari (src/ModbusRtu.h) birim testleri:  pio test -e native -f test_modbus_rtu
// Bilinen test vektorleri: EVOTOMASYON_TASKS.md Adim 3.2 (Waveshare 0x05 ON/OFF cerceveleri),
// WS_RS485.cpp (toggle cercevesi) ve yaygin Modbus ornekleri.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "ModbusRtu.h"

using namespace modbus;

void setUp(void) {}
void tearDown(void) {}

// Cerceveyi (CRC dahil) olusturup dizi icine yazan kucuk yardimci
static size_t makeFrame(uint8_t* out, const uint8_t* body, size_t n) {
  for (size_t i = 0; i < n; i++) out[i] = body[i];
  appendCrc(out, n);
  return n + 2;
}

void test_crc16_known_vectors(void) {
  // 01 05 00 00 FF 00  -> 8C 3A   (EVOTOMASYON_TASKS Adim 3.2: ON)
  const uint8_t on[6] = {0x01, 0x05, 0x00, 0x00, 0xFF, 0x00};
  TEST_ASSERT_EQUAL_HEX16(0x3A8C, crc16(on, 6));
  // 01 05 00 00 00 00  -> CD CA   (OFF)
  const uint8_t off[6] = {0x01, 0x05, 0x00, 0x00, 0x00, 0x00};
  TEST_ASSERT_EQUAL_HEX16(0xCACD, crc16(off, 6));
  // 01 05 00 00 55 00  -> F2 9A   (Waveshare toggle, WS_RS485.cpp)
  const uint8_t tog[6] = {0x01, 0x05, 0x00, 0x00, 0x55, 0x00};
  TEST_ASSERT_EQUAL_HEX16(0x9AF2, crc16(tog, 6));
  // 01 01 00 00 00 08 -> 3D CC ; 01 02 00 00 00 08 -> 79 CC ; 01 03 00 00 00 02 -> C4 0B
  const uint8_t rc[6] = {0x01, 0x01, 0x00, 0x00, 0x00, 0x08};
  TEST_ASSERT_EQUAL_HEX16(0xCC3D, crc16(rc, 6));
  const uint8_t rd[6] = {0x01, 0x02, 0x00, 0x00, 0x00, 0x08};
  TEST_ASSERT_EQUAL_HEX16(0xCC79, crc16(rd, 6));
  const uint8_t rh[6] = {0x01, 0x03, 0x00, 0x00, 0x00, 0x02};
  TEST_ASSERT_EQUAL_HEX16(0x0BC4, crc16(rh, 6));
}

void test_build_write_coil_matches_documented_frames(void) {
  uint8_t f[8];
  buildWriteCoil(f, 0x01, 0x0000, COIL_ON);
  const uint8_t on[8] = {0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3A};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(on, f, 8);
  buildWriteCoil(f, 0x01, 0x0000, COIL_OFF);
  const uint8_t off[8] = {0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xCD, 0xCA};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(off, f, 8);
  buildWriteCoil(f, 0x01, 0x0000, COIL_TOGGLE);
  const uint8_t tog[8] = {0x01, 0x05, 0x00, 0x00, 0x55, 0x00, 0xF2, 0x9A};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(tog, f, 8);
}

void test_build_read_bits(void) {
  uint8_t f[8];
  buildReadBits(f, 0x01, FC_READ_COILS, 0, 8);
  const uint8_t c[8] = {0x01, 0x01, 0x00, 0x00, 0x00, 0x08, 0x3D, 0xCC};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(c, f, 8);
  buildReadBits(f, 0x01, FC_READ_DISCRETE_INPUTS, 0, 8);
  const uint8_t d[8] = {0x01, 0x02, 0x00, 0x00, 0x00, 0x08, 0x79, 0xCC};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(d, f, 8);
}

void test_frame_crc_check(void) {
  const uint8_t good[8] = {0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3A};
  TEST_ASSERT_TRUE(frameCrcOk(good, 8));
  uint8_t bad[8] = {0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3B};
  TEST_ASSERT_FALSE(frameCrcOk(bad, 8));
  TEST_ASSERT_FALSE(frameCrcOk(good, 3));      // cok kisa
  TEST_ASSERT_FALSE(frameCrcOk(good, 0));
}

// ---------------------------------------------------------------- 0x05 yanki dogrulamasi
void test_write_coil_echo_ok(void) {
  uint8_t req[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  TEST_ASSERT_EQUAL_UINT8(OK, checkWriteCoilEcho(req, 8, req, 8));
}

void test_write_coil_no_data_and_short(void) {
  uint8_t req[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  TEST_ASSERT_EQUAL_UINT8(ERR_NO_DATA, checkWriteCoilEcho(req, 8, req, 0));
  TEST_ASSERT_EQUAL_UINT8(ERR_SHORT, checkWriteCoilEcho(req, 8, req, 3));
  TEST_ASSERT_EQUAL_UINT8(ERR_SHORT, checkWriteCoilEcho(req, 8, req, 4));
}

void test_write_coil_bad_crc_rejected(void) {
  uint8_t req[8], rx[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  for (int i = 0; i < 8; i++) rx[i] = req[i];
  rx[7] ^= 0x01;
  TEST_ASSERT_EQUAL_UINT8(ERR_CRC, checkWriteCoilEcho(req, 8, rx, 8));
}

void test_write_coil_wrong_slave_rejected(void) {
  uint8_t req[8], rx[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  buildWriteCoil(rx, 0x02, 3, COIL_ON);        // baska slave'in gecerli CRC'li yaniti
  TEST_ASSERT_EQUAL_UINT8(ERR_SLAVE, checkWriteCoilEcho(req, 8, rx, 8));
}

void test_write_coil_echo_mismatch_rejected(void) {
  uint8_t req[8], rx[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  buildWriteCoil(rx, 0x01, 3, COIL_OFF);       // CRC gecerli ama deger farkli: ON istedik, OFF yanki geldi
  TEST_ASSERT_EQUAL_UINT8(ERR_ECHO, checkWriteCoilEcho(req, 8, rx, 8));
  buildWriteCoil(rx, 0x01, 4, COIL_ON);        // baska coil
  TEST_ASSERT_EQUAL_UINT8(ERR_ECHO, checkWriteCoilEcho(req, 8, rx, 8));
}

void test_write_coil_exception_response(void) {
  uint8_t req[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  const uint8_t body[3] = {0x01, 0x85, 0x02};   // 0x05|0x80, exception 02 (illegal data address)
  uint8_t rx[5];
  size_t n = makeFrame(rx, body, 3);
  uint8_t exc = 0;
  TEST_ASSERT_EQUAL_UINT8(ERR_EXCEPTION, checkWriteCoilEcho(req, 8, rx, n, &exc));
  TEST_ASSERT_EQUAL_UINT8(2, exc);
}

void test_write_coil_wrong_function_rejected(void) {
  uint8_t req[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  uint8_t rx[8];
  const uint8_t body[6] = {0x01, 0x06, 0x00, 0x03, 0xFF, 0x00};   // 0x06 yaniti geldi
  size_t n = makeFrame(rx, body, 6);
  TEST_ASSERT_EQUAL_UINT8(ERR_FUNC, checkWriteCoilEcho(req, 8, rx, n));
}

void test_write_coil_length_mismatch_rejected(void) {
  uint8_t req[8];
  buildWriteCoil(req, 0x01, 3, COIL_ON);
  uint8_t rx[9];
  const uint8_t body[7] = {0x01, 0x05, 0x00, 0x03, 0xFF, 0x00, 0x00};   // 9 bayt, CRC gecerli
  size_t n = makeFrame(rx, body, 7);
  TEST_ASSERT_EQUAL_UINT8(ERR_LENGTH, checkWriteCoilEcho(req, 8, rx, n));
}

// ---------------------------------------------------------------- 0x01 / 0x02 okuma yanitlari
void test_read_bits_ok_and_bit_extraction(void) {
  // 8 coil, veri 0b00000101 (coil 0 ve 2 acik)
  const uint8_t body[4] = {0x01, 0x01, 0x01, 0x05};
  uint8_t rx[6];
  size_t n = makeFrame(rx, body, 4);
  const uint8_t* data = nullptr;
  uint8_t bc = 0;
  TEST_ASSERT_EQUAL_UINT8(OK, checkReadBits(0x01, FC_READ_COILS, 8, rx, n, &data, &bc));
  TEST_ASSERT_EQUAL_UINT8(1, bc);
  TEST_ASSERT_TRUE(getBit(data, bc, 0));
  TEST_ASSERT_FALSE(getBit(data, bc, 1));
  TEST_ASSERT_TRUE(getBit(data, bc, 2));
  TEST_ASSERT_FALSE(getBit(data, bc, 7));
  TEST_ASSERT_FALSE(getBit(data, bc, 8));     // aralik disi
}

void test_read_bits_16_channels(void) {
  const uint8_t body[5] = {0x01, 0x02, 0x02, 0x01, 0x80};      // bit0 ve bit15 acik
  uint8_t rx[7];
  size_t n = makeFrame(rx, body, 5);
  const uint8_t* data = nullptr;
  uint8_t bc = 0;
  TEST_ASSERT_EQUAL_UINT8(OK, checkReadBits(0x01, FC_READ_DISCRETE_INPUTS, 16, rx, n, &data, &bc));
  TEST_ASSERT_TRUE(getBit(data, bc, 0));
  TEST_ASSERT_TRUE(getBit(data, bc, 15));
  TEST_ASSERT_FALSE(getBit(data, bc, 8));
}

void test_read_bits_rejects_bad_responses(void) {
  const uint8_t* data = nullptr;
  uint8_t bc = 0;
  uint8_t rx[8];

  // CRC bozuk
  const uint8_t b1[4] = {0x01, 0x01, 0x01, 0x05};
  size_t n = makeFrame(rx, b1, 4);
  rx[n - 1] ^= 0xFF;
  TEST_ASSERT_EQUAL_UINT8(ERR_CRC, checkReadBits(0x01, FC_READ_COILS, 8, rx, n, &data, &bc));

  // yanlis slave
  n = makeFrame(rx, b1, 4);
  TEST_ASSERT_EQUAL_UINT8(ERR_SLAVE, checkReadBits(0x02, FC_READ_COILS, 8, rx, n, &data, &bc));

  // yanlis islev
  TEST_ASSERT_EQUAL_UINT8(ERR_FUNC, checkReadBits(0x01, FC_READ_DISCRETE_INPUTS, 8, rx, n, &data, &bc));

  // bayt sayisi uyusmuyor (16 bit istendi, 1 bayt geldi)
  TEST_ASSERT_EQUAL_UINT8(ERR_LENGTH, checkReadBits(0x01, FC_READ_COILS, 16, rx, n, &data, &bc));

  // bayt sayisi dogru ama fazladan bayt var
  const uint8_t b2[5] = {0x01, 0x01, 0x01, 0x05, 0x00};
  n = makeFrame(rx, b2, 5);
  TEST_ASSERT_EQUAL_UINT8(ERR_LENGTH, checkReadBits(0x01, FC_READ_COILS, 8, rx, n, &data, &bc));

  // bos / kisa
  TEST_ASSERT_EQUAL_UINT8(ERR_NO_DATA, checkReadBits(0x01, FC_READ_COILS, 8, rx, 0, &data, &bc));
  TEST_ASSERT_EQUAL_UINT8(ERR_SHORT, checkReadBits(0x01, FC_READ_COILS, 8, rx, 3, &data, &bc));
}

void test_read_bits_exception(void) {
  const uint8_t body[3] = {0x01, 0x81, 0x02};
  uint8_t rx[5];
  size_t n = makeFrame(rx, body, 3);
  const uint8_t* data = nullptr;
  uint8_t bc = 0, exc = 0;
  TEST_ASSERT_EQUAL_UINT8(ERR_EXCEPTION, checkReadBits(0x01, FC_READ_COILS, 8, rx, n, &data, &bc, &exc));
  TEST_ASSERT_EQUAL_UINT8(2, exc);
}

void test_expected_response_length(void) {
  TEST_ASSERT_EQUAL_UINT32(8, expectedResponseLen(FC_WRITE_SINGLE_COIL, 0));
  TEST_ASSERT_EQUAL_UINT32(6, expectedResponseLen(FC_READ_COILS, 8));
  TEST_ASSERT_EQUAL_UINT32(7, expectedResponseLen(FC_READ_DISCRETE_INPUTS, 16));
  TEST_ASSERT_EQUAL_UINT32(9, expectedResponseLen(FC_READ_COILS, 32));
  TEST_ASSERT_EQUAL_UINT32(6, expectedResponseLen(FC_READ_COILS, 1));
  TEST_ASSERT_EQUAL_UINT32(0, expectedResponseLen(0x7F, 8));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_crc16_known_vectors);
  RUN_TEST(test_build_write_coil_matches_documented_frames);
  RUN_TEST(test_build_read_bits);
  RUN_TEST(test_frame_crc_check);
  RUN_TEST(test_write_coil_echo_ok);
  RUN_TEST(test_write_coil_no_data_and_short);
  RUN_TEST(test_write_coil_bad_crc_rejected);
  RUN_TEST(test_write_coil_wrong_slave_rejected);
  RUN_TEST(test_write_coil_echo_mismatch_rejected);
  RUN_TEST(test_write_coil_exception_response);
  RUN_TEST(test_write_coil_wrong_function_rejected);
  RUN_TEST(test_write_coil_length_mismatch_rejected);
  RUN_TEST(test_read_bits_ok_and_bit_extraction);
  RUN_TEST(test_read_bits_16_channels);
  RUN_TEST(test_read_bits_rejects_bad_responses);
  RUN_TEST(test_read_bits_exception);
  RUN_TEST(test_expected_response_length);
  return UNITY_END();
}
