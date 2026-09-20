#include "WS_ETH.h"

#include <NTPClient.h>
#include <WiFiUdp.h>

static bool eth_connected = false;
static bool eth_connected_Old = false;
IPAddress ETH_ip;
// NTP setup
WiFiUDP udp;
NTPClient timeClient(udp, "pool.ntp.org", timezone*3600, 60000);  // NTP server, time offset in seconds, update interval

#if defined(ESP_IDF_VERSION_MAJOR) && (ESP_IDF_VERSION_MAJOR >= 5)
void onEvent(arduino_event_id_t event, arduino_event_info_t info) {
  switch (event) {
    case ARDUINO_EVENT_ETH_START:
      printf("ETH Started\r\n");
      ETH.setHostname("esp32-eth0");
      break;
    case ARDUINO_EVENT_ETH_CONNECTED: printf("ETH Connected\r\n"); break;
    case ARDUINO_EVENT_ETH_GOT_IP:
      ETH_ip = ETH.localIP(); 
      printf("ETH Got IP: %d.%d.%d.%d\n", ETH_ip[0], ETH_ip[1], ETH_ip[2], ETH_ip[3]);
      eth_connected = true;
      break;
    case ARDUINO_EVENT_ETH_DISCONNECTED:
      printf("ETH Disconnected\r\n");
      eth_connected = false;
      break;
    case ARDUINO_EVENT_ETH_STOP:
      printf("ETH Stopped\r\n");
      eth_connected = false;
      break;
    default: break;
  }
}
#endif

void testClient(const char *host, uint16_t port) {
  printf("\nconnecting to %s\r\n", host);
  WiFiClient client;
  if (!client.connect(host, port)) {
    printf("connection failed\r\n");
    return;
  }
  client.printf("GET / HTTP/1.1\r\nHost: %s\r\n\r\n", host);
  while (client.connected() && !client.available());
  while (client.available()) {
    printf("%c",(char)client.read());
  }
  printf("closing connection\n");
  client.stop();
}

void ETH_Init(void) {
  printf("Ethernet: Ready (Wi-Fi primary mode)\r\n");
}
void EthernetTask(void *parameter) {
  while(1){
    if (eth_connected && !eth_connected_Old) {
      eth_connected_Old = eth_connected;
      RGB_Open_Time(0, 60, 0,1000, 0); 
      printf("Network port connected!\r\n");
      Acquisition_time();
    }
    else if(!eth_connected && eth_connected_Old){
      eth_connected_Old = eth_connected;
      printf("Network port disconnected!\r\n");
    }
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  vTaskDelete(NULL);
}
void Acquisition_time(void) {                                   // Get the network time and set to DS3231 to be called after the WIFI connection is successful
  timeClient.begin();
  timeClient.update();

  time_t currentTime = timeClient.getEpochTime();
  while(currentTime < 1609459200)                           // Using the current timestamp to compare with a known larger value,1609459200 is a known larger timestamp value that corresponds to January 1, 2021
  {
    timeClient.update();  
    currentTime = timeClient.getEpochTime();
    printf("ETH - Online clock error!!!\r\n");
  }
  struct tm *localTime = localtime(&currentTime);
  static datetime_t PCF85063_Time = {0};
  PCF85063_Time.year = localTime->tm_year + 1900;
  PCF85063_Time.month = localTime->tm_mon + 1;
  PCF85063_Time.day = localTime->tm_mday;
  PCF85063_Time.dotw = localTime->tm_wday;
  PCF85063_Time.hour = localTime->tm_hour;
  PCF85063_Time.minute = localTime->tm_min;
  PCF85063_Time.second = localTime->tm_sec;
  PCF85063_Set_All(PCF85063_Time);
}
