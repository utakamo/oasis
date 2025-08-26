# OpenWrt AI Assistant Application - Oasis (v3.0.0)
> [!IMPORTANT]
> >
> **Support AI Service**
> - OpenAI
> - Ollama
> - Anthropic (Work in Progress)
> - Google Gemini (Work in Progress)
> - OpenRouter (Work in Progress)

This software provides the ability to link OpenWrt and AI. Based on user input, the AI provides the optimal settings for OpenWrt; the OpenWrt device itself analyzes the information provided by the AI, verifies the validity of that information, and then notifies the user.

|  Application  |         description       |
| :---: | :---  |
|   oasis    |   AI chat core software (provides stand-alone CUI-based chat functionality)   |
|  luci-app-oasis |   This is a plugin to use AI chat from within LuCI's WebUI. (base software is oasis)  |
<img width="936" height="445" alt="Image" src="https://github.com/user-attachments/assets/169aa8dd-e3c1-4f44-a1d9-0e5d452a5fd0" />

## How to install oasis all Packages
Dependency: lua-curl-v3, luci-compat  
  
The Oasis package can be found under "oasis-2.0.1" in the Releases section of this GitHub page. It is a device-independent package, but it requires dependency packages such as lua-curl-v3 and luci-compat. Typically, if you install Oasis on an OpenWrt device with an active internet connection, these dependency packages will be downloaded and installed automatically.  
  
If the repository corresponding to the device being used as an OpenWrt device does not include lua-curl-v3 or luci-compat, users will need to build the dependency packages themselves using the OpenWrt Buildroot and install them on the OpenWrt device.
### 1. Install Packages via the Command Line
```
root@OpenWrt:~# wget -O oasis_2.0.1-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v2.0.1/oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# wget -O luci-app-oasis_2.0.1-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v2.0.1/luci-app-oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# opkg update
root@OpenWrt:~# opkg install oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# opkg install luci-app-oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# reboot
```

## AI Setting
[Main] ---> [Network] ---> [Oasis] ---> [General Setting]
### 1. Example OpenAI Setup
<img width="940" height="319" alt="Image" src="https://github.com/user-attachments/assets/c7c9d912-bee7-420e-871c-5d252c58ebcf" />

> [!NOTE]
> #### 1.1. OpenAI Endpoint
> If you want to use OpenAI, you need to set the Endpoint Type.
> - Default Endpoint ----> https://api.openai.com/v1/chat/completions
> - Custom Endpoint ----> User-specified endpoint
>
> #### 1.2. OpenAI API Key  
> Please create an API Key on your OpenAI Platform page.  
>
> #### 1.3. OpenAI LLM Models (Example)
> - gpt-3.5-turbo
> - gpt-4
> - gpt-4o
> - etc...
>  
> For details, please refer to the OpenAI website.

### 2. Example Ollama Setup
<img width="853" alt="Image" src="https://github.com/user-attachments/assets/7cc74e68-c920-4f2a-b0df-c0eba7264774" />

> [!NOTE]
> #### 2.1. About Ollama (AI Server) Setup
> If you want to use Ollama, you need to set the Ollama parameters (OLLAMA_HOST and OLLAMA_ORIGINS) with the values shown below.  
> ```
> OLLAMA_HOST=0.0.0.0
> OLLAMA_ORIGINS=*
> ```
> Change the Ollama parameter configuration file (Linux) or environment variables (Windows) that exist on the PC where Ollama is installed to the above values.
>   
> My technical blog has an introductory page on the above Ollama setup, which describes the setup on Windows and Linux (Japanese Page).
> https://utakamo.com/article/ai/llm/ollama/setup/index.html#network-support
>
> #### 2.2. Ollama Endpoint
> Ollama Endpoint Format: ```http://<Your Ollama PC Address>:11434/api/chat ```  
> In the example above, Ollama's IP address is 192.168.1.109/24, so ```http://192.168.1.109:11434/api/chat``` is set as the endpoint.
>
> #### 2.3. Ollama API Key
> When using Ollama, an API key is typically not required, so nothing needs to be entered in the API Key field on this settings page.
>
> #### 2.4. LLM Models
> https://ollama.com/library

## 1. Chat with AI
[Main] ---> [Network] ---> [Oasis] ---> [Chat with AI]
<img width="940" height="447" alt="Image" src="https://github.com/user-attachments/assets/0e264254-1c3f-4a66-80ad-833145b7421a" />  
When chatting with AI for the first time, you can choose what topics to talk about. These options can be freely added or removed by the user in the System Message tab.  
<img width="940" height="447" alt="Image" src="https://github.com/user-attachments/assets/858c0e13-fee5-46d1-9da0-37ab30879bd4" />  
When a chat with AI begins, it is given a title and displayed in the chat list on the left side.
"Users can continue chatting with AI, and if there is chat data from the past, they can select it to resume the conversation.
<img width="943" height="440" alt="Image" src="https://github.com/user-attachments/assets/0fcd1d52-a875-4c53-835a-bc1c9a157d7a" />  
Chat data can be renamed, exported, or deleted.
<img width="938" height="446" alt="Image" src="https://github.com/user-attachments/assets/283debb0-638e-4b1e-b58c-4eb770899b15" />  

## Ask OpenWrt Setting (Basic Usage)
Oasis is customizing the AI to specialize in OpenWrt. Therefore, it may prompt users to ask about OpenWrt. If a user requests configuration related to OpenWrt, the AI will suggest changes using UCI commands.  
<img width="937" height="444" alt="Image" src="https://github.com/user-attachments/assets/50654f91-c59e-462a-a392-06b1e3bfd297" /> 
When a configuration change is suggested by the AI using UCI commands, the internal system of OpenWrt recognizes that a configuration change has been proposed by the AI. It then notifies the user via a popup to apply the configuration change to the current runtime. The user can accept the configuration change by pressing the Apply button.  
<img width="932" height="447" alt="Image" src="https://github.com/user-attachments/assets/f02c8f4e-db37-444a-9b98-e3d281321eaa" />
<img width="938" height="446" alt="Image" src="https://github.com/user-attachments/assets/7959e63b-391c-4f89-821d-1449328e301e" />
After applying the settings, if the user can access the WebUI, they will be notified in the Oasis chat screen to finalize the configuration change suggested by the AI. The user can press the Finalize button to approve the configuration change, or press the Rollback button to reject it.  
<img width="946" alt="Image" src="https://github.com/user-attachments/assets/081313e4-e3ad-405f-a75b-ff4a46c83684" />
> [!IMPORTANT]
> After a configuration change, if the user does not press the Finalize or Rollback button within 5 minutes (default), the configuration will automatically rollback (Rollback monitoring). This ensures that even if there was a configuration error that caused a brick, the system will return to the original, normal settings. Note: If the OpenWrt device is powered off during the rollback monitoring period, the rollback monitoring will resume upon restart.

## Ask OpenWrt Setting (Advanced Usage)
> [!NOTE]
> The following is an effective usage method when using high-performance LLMs such as OpenAI.

If you are willing to provide your current settings to the AI, you can select UCI Config from the dropdown menu below the message box. When you provide this as supplementary information when making a request to the AI, the accuracy of its suggestions will improve significantly. For example, as shown in the following case.

In the following example, Wi-Fi is enabled, and when requesting some configuration changes, the current wireless settings are provided to the AI as reference information.
<img width="854" alt="Image" src="https://github.com/user-attachments/assets/4d58b2e9-82eb-43cc-b90f-11597760994e" />  
When you send a message to the AI, the selected configuration information (e.g., wireless settings) will be added at the bottom.  
> [!IMPORTANT]
> After pressing the Send button, select ```OpenWrt Teacher (for High-Performance LLM)``` from the list of system messages displayed.
<img width="849" alt="Image" src="https://github.com/user-attachments/assets/7abdfb17-9997-411a-9c56-1646deb1cb03" />  

By providing the current configuration information, the accuracy of the AI's suggestions improves.  
<img width="844" alt="Image" src="https://github.com/user-attachments/assets/67a330b1-0767-4a22-b9a7-e8683a6833f2" />  
<img width="833" alt="Image" src="https://github.com/user-attachments/assets/6228d327-f388-4ba9-8b35-2b50c58d24a9" />  
<img width="835" alt="Image" src="https://github.com/user-attachments/assets/a4e9c003-aa5f-433f-a337-af9e40046d31" />  

## Rollback Data List
AI-driven configuration changes are saved as rollback data, allowing users to revert settings to any desired point.
<img width="857" alt="Image" src="https://github.com/user-attachments/assets/9b344f7f-3cee-44ae-9fd0-eeaf5bc5c855" />  

## System Message (Knowledge)
In Oasis, users can create and save system messages to use when starting a chat with AI. System messages are preloaded data used by AI to respond to the user.
For example, add a message like the following as a system message to instruct the AI to interpret English and Japanese.
<img width="954" height="440" alt="image" src="https://github.com/user-attachments/assets/1415cb9a-198f-47e7-8921-a963516a1772" />  
Enter the instructions for the AI into the text area of 'Create System Message' and press the Add button to add it to the System Message List. This will register a new System Message called 'Translator.'
<img width="932" height="430" alt="image" src="https://github.com/user-attachments/assets/4108e2c0-d439-4bb6-8937-0ffd787a869d" />  
When you return to the Chat with AI tab and start a new chat with the AI, 'Translator' will appear as a topic option.
<img width="936" height="446" alt="image" src="https://github.com/user-attachments/assets/001aa57f-9cb9-4299-b0a9-4ab73288079a" />  
When 'Translator' is selected, the user's English message will be translated into Japanese by the AI.
<img width="934" height="447" alt="image" src="https://github.com/user-attachments/assets/1d3ddcc5-5e43-4c55-bcb0-67b6467e71af" />  
In this way, by including instructions or specific knowledge for the AI as system messages, it is possible to modify the AI's behavior toward users.
Currently, Oasis adjusts responses related to OpenWrt solely through system messages.
As a result, by storing information about OpenWrt settings as knowledge in existing or new system messages, it will become specialized in modifying OpenWrt settings.
In particular, Oasis analyzes whether content related to modifying OpenWrt settings (UCI command sequences) found within AI responses can be executed. Then, it notifies the user with a popup.

## Oasis Local Tool(OLT) Server
By installing oasis-mod-tool, an extension module for Oasis, the AI will be able to use the tools. After installation, you can optionally enable AI tools from the Tools tab.  
<img width="935" height="443" alt="Image" src="https://github.com/user-attachments/assets/7c13d8c5-1da3-4c06-842b-13481226863b" />
The following is an example with both get_ip_addr and get_ifname_list enabled.  
<img width="941" height="428" alt="Image" src="https://github.com/user-attachments/assets/584c41bd-718b-46f5-9dab-cda7379d0362" />
By enabling the tools, the AI will begin using them in response to user requests.  
<img width="934" height="446" alt="Image" src="https://github.com/user-attachments/assets/82944040-30f8-44ef-82bd-67b9a9157f4a" />

> [!IMPORTANT]
> This feature requires that the AI supports tool usage. OpenAI's AI can use tools.
> However, when using Ollama, some AIs may not support tool usage.
> For details on which Ollama AIs support tools, please refer to the URL below.  
> https://ollama.com/blog/tool-support

## Select AI Icon
In Oasis, users can freely change the AI's chat icon to create a sense of familiarity with the AI.
<img width="944" height="421" alt="Image" src="https://github.com/user-attachments/assets/c5fb33c2-5b66-4799-ac04-76923ec58b5b" />  
Click your preferred icon image and press the Select button to apply the setting. 
<img width="938" height="416" alt="image" src="https://github.com/user-attachments/assets/ba52f754-2da4-4762-bcbf-e3883a4adad6" />  
<img width="927" height="446" alt="image" src="https://github.com/user-attachments/assets/2e96eaf4-a02c-442c-aca1-1af4dafb2063" />  
To add your favorite icon image (e.g., png), drag and drop it or click under Upload Icon.
<img width="930" height="421" alt="image" src="https://github.com/user-attachments/assets/0ad89b02-221f-4a5d-8b30-070cc5112a28" />  
Pressing the Upload button stores the icon in the OpenWrt device.
<img width="940" height="414" alt="image" src="https://github.com/user-attachments/assets/bb24980e-0b37-42c2-99d4-8ff622fa600f" />  

## How to install only oasis
Dependency: lua-curl-v3
```
root@OpenWrt:~# wget -O oasis_2.0.1-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v2.0.1/oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# opkg update
root@OpenWrt:~# opkg install oasis_2.0.1-r1_all.ipk
root@OpenWrt:~# service rpcd reload
```

## Commands
```
root@OpenWrt:~# oasis
Usage: oasis <command> [[<options>] arguments]...

Options:
 -u <Endpoint>          Set the  AI Service Endpoint(URL)
 -k <api-key>           Set the API key
 -m <model>             Set the LLM model
 -p <storage>           Set the storage path
 -s <system message>    Set the new system message (for sysmsg command)
 -c <sysmsg key>        Set the system message key (for sysmsg command)

Commands:
 storage <path> [<chat-max>]
 add [<service> [<endpoint> [<api-key> [<model> [<storage>]]]]]
 change <service-id> [<options> <value>]...
 select [<service-id>]
 delete <service-id>
 chat [id=<chat-id>]
 prompt <message>
 sysmsg [<chat|prompt> <options> <value>]
 delchat id=<chat-id>
 rename id=<chat-id> <title>
 list
 tools

Docs:
 https://github.com/utakamo/oasis
```
## Usage
### Step1: Setting up ai service  
- Example of OpenAI
```
root@OpenWrt:~# oasis add
Service ("Ollama" or "OpenAI")                             >> OpenAI
Endpoint(url)                                              >> https://api.openai.com/v1/chat/completions
API KEY (leave blank if none)                              >> <your_api-key>
LLM MODEL                                                  >> gpt-4
```

- Example of local ai service (Ollama) 
```
root@OpenWrt:~# oasis add
Service ("Ollama" or "OpenAI")                             >> Ollama
Endpoint(url)                                              >> http://192.168.3.16:11434/api/chat       
API KEY (leave blank if none)                              >>
LLM MODEL                                                  >> gemma2:2b
``````

### Step2: Select AI Service
- The first service registered with the oasis add command is selected.　
<img width="415" alt="aihelper_select_service01" src="https://github.com/user-attachments/assets/0000d1c1-9b38-4e28-bb95-fcb8387c5ae1">

- To switch to another AI service, run oasis select <service-name>. The following is an example of switching the service in use to my-ollama.
<img width="455" alt="aihelper_select_service02" src="https://github.com/user-attachments/assets/befe2830-0364-4c81-937a-bd1c9168f522">

### Step3: Example of chat with ai
```
root@OpenWrt:~# oasis chat
You :Hello!

gemma2:2b
Hello! 👋  

How can I help you today? 😄
Title:ConversationStart  ID:7772532380

You :/history
{"messages":[{"content":"Hello!","role":"user"},{"content":"Hello! 👋 How can I help you today? 😊 \n","role":"assistant"}],"model":"gemma2:2b"}

You :exit
```
|  slash cmd  |         description       |
| :---: | :---  |
|   /exit    |   Terminate the chat with the AI.   |
|  /history |   Display the chat history(JSON)  |

### Step4: Load past chats and resume conversation.
Confirm Chat ID
```
root@OpenWrt:~# oasis list
-----------------------------------------------------
 No. | title                          | id
-----------------------------------------------------
[ 1]: Hello                            5727149461
[ 2]: ConversationStart                7772532380
```
Resume conversation with the AI by specifying the chat ID.
```
root@OpenWrt:~# oasis chat id=7772532380
You :Hello!

gemma2:2b
Hello! 👋 How can I help you today? 😊

You :
```
### Step5: How to send prompt to AI
```
root@OpenWrt:~# oasis prompt "Hello!!"
Hello! 👋  What can I do for you today? 😊 

root@OpenWrt:~# 
```

# Oasis RPC (json-rpc2.0)
Dependency Package: `uhttpd-mod-ubus`
> [!NOTE]
> If you wish to use this functionality, you may need to install uhttpd-mod-ubus.
> ```
> root@OpenWrt~# opkg update
> root@OpenWrt~# opkg install uhttpd-mod-ubus
> ```

Oasis supports RPC functionality.  
If you want to use the RPC feature, please check the RPC radio button on the Oasis settings page.
<img width="747" alt="Image" src="https://github.com/user-attachments/assets/1829e60d-a420-45e7-962e-5dbc03787036" />

The following is an example of message request and response exchange utilizing Oasis's RPC function. The assumed router credentials are as follows:  
- Username: `root`
- Password: `12345678`
- OpenWrt Device Ip address: `192.168.1.1/24`  

## 1. Create ubus rpc session id
- [Request]  
`
curl -H 'Content-Type: application/json' -d '{ "jsonrpc": "2.0", "id": 1, "method": "call", "params": [ "00000000000000000000000000000000", "session", "login", { "username": "root", "password": "12345678"  } ] }'  http://192.168.1.1/ubus
`  
- [Response (Example)]  
`
{"jsonrpc":"2.0","id":1,"result":[0,{"ubus_rpc_session":"3cc578e5bc9f2b032c6445ea5696c9c8","timeout":300,"expires":299, ... 
`

The ubus_rpc_session in this response will be used for sending subsequent requests. In this example, the ubus_rpc_session is `3cc578e5bc9f2b032c6445ea5696c9c8`, so this number is used in the next request submission example.

## 2. Get base infomation for ai chat
- [Request]  
`
curl -H 'Content-Type: application/json' -d '{ "jsonrpc": "2.0", "id": 1, "method": "call", "params": [ "3cc578e5bc9f2b032c6445ea5696c9c8", "oasis", "base_info", {} ] }'  http://192.168.1.1/ubus
`  
- [Response (Example)]  
`
{"jsonrpc":"2.0","id":1,"result":[0,{"sysmsg":[{"key":"default","title":"OpenWrt Teacher (for High-Performance LLM)"},{"key":"custom_1","title":"OpenWrt System Knowledge (Sample)"},{"key":"custom_2","title":"OpenWrt Network Knowledge (Sample)"}],"configs":["dhcp","dropbear","firewall","luci","network","system","ubihealthd","uhttpd","wireless"],"service":[{"identifier":"1270318202","name":"OpenAI","model":"gpt-4"},{"identifier":"5336525023","name":"Ollama","model":"gemma2:2b"}],"icon":{"list":{"icon_1":"openwrt.png","icon_2":"operator.png"},"ctrl":{"using":"icon_1","path":"/www/luci-static/resources/oasis/"}},"chat":{"item":[{"id":"1873851023","title":"UIThemeChange"},{"id":"3598688228","title":"OpenWrtUIThemeChanges"},{"id":"6053520290","title":"\"ConfiguringWi-FiSettingsinOpenWrt\""},{"id":"3850114087","title":"\"GuidetoBasicOpenWrtNetworkandWi-FiSettingsUsingUCICommands\""}]}}]}
`

By sending and receiving the above request and response, you obtain the basic information needed to start the chat. The basic information includes system messages (knowledge) and corresponding keys, which can be properly specified in the fields for chat message requests explained next, allowing you to send messages to the AI.

## 3. Send user message (Initial conversation)
- [Request]  
`
curl -H 'Content-Type: application/json' -d '{ "jsonrpc": "2.0", "id": 1, "method": "call", "params": [ "3cc578e5bc9f2b032c6445ea5696c9c8", "oasis.chat", "send", {"id": "", "sysmsg_key": "default", "message": "Hello!!"} ] }'  http://192.168.1.1/ubus
`  
- [Response (Example)]  
`
{"jsonrpc":"2.0","id":1,"result":[0,{"id":"6441905234","uci_parse_tbl":{"status":"No Parsing ..."},"content":"Hello! How can I assist you with OpenWrt today?","title":"\"OpenWrtAssistanceSessionIntroduction\""}]}
`  

The AI's response in the initial conversation includes a chat ID (Ex: `6441905234`). To continue the conversation, you need to include this chat ID when sending a message."

## 4. Send user message (Subsequent conversations)
- [Request]
`
curl -H 'Content-Type: application/json' -d '{ "jsonrpc": "2.0", "id": 1, "method": "call", "params": [ "c5b484940761463117b0ab5d4a6105e7", "oasis.chat", "send", {"id": "6441905234", "sysmsg_key": "default", "message": "Please change the hostname to utakamo.
"} ] }'  http://192.168.1.1/ubus
`
- [Response (Example)]  
`
{"jsonrpc":"2.0","id":1,"result":[0,{"content":"Sure, you can change the hostname to 'utakamo' using the UCI command. Here are the steps you need to follow:\n\n1. Open a terminal.\n\n2. Enter the following command:\n\n```bash\nuci set system.@system[0].hostname='utakamo'\n```\n\nNow, your system's hostname should be updated to 'utakamo'. Please let me know if you have any other questions or tasks!","uci_parse_tbl":{"uci_notify":true,"uci_list":{"delete":[],"set":[{"class":{"option":"hostname","config":"system","value":"'utakamo'","section":"@system[0]"},"param":"system.@system[0].hostname='utakamo'"}],"del_list":[],"reorder":[],"add_list":[],"add":[]}}}]}
`  

## 5. Load chat data
- [Request]  
`
curl -H 'Content-Type: application/json' -d '{ "jsonrpc": "2.0", "id": 1, "method": "call", "params": [ "3cc578e5bc9f2b032c6445ea5696c9c8", "oasis.chat", "load", {"id": "0132179937"} ] }'  http://192.168.1.1/ubus
`
- [Response (Example)]  
`
{"jsonrpc":"2.0","id":1,"result":[0,{"messages":[{"content":"You are an AI that listens to user requests and suggests changes to OpenWrt settings.\nWhen a user requests changes to network or Wi-Fi settings, please suggest the OpenWrt UCI commands that will achieve the user's expected settings.\nIf the user asks questions unrelated to OpenWrt settings, there is no need to answer about OpenWrt settings.\nRegarding network and Wi-Fi settings using OpenWrt UCI commands, I will teach you the following basic content.\n[1] Setup AP setting\nStep1: Activate Wi-Fi\n```\nuci set wireless.radio0.disabled=0\nuci set wireless.radio0.country=JP\nuci set wireless.radio0.txpower=10\nuci set wireless.default_radio0.ssid=OpenWrt\nuci set wireless.default_radio0.encryption=psk2\nuci set wireless.default_radio0.key=OpenWrt1234\n```\nThe value of wireless.default_radio0.key should be an appropriate string in the following format.\nFormat: alphanumeric characters + special characters, 8~63 characters\nStep2: Accept IP address assignment by DHCP server.\n```\nuci set network.lan.proto=dhcp\n```\n[2] Setup Basic Router setting\nStep1: Activate Wi-Fi\n```\nuci set wireless.radio0.disabled=0\nuci set wireless.radio0.country=JP\nuci set wireless.radio0.txpower=10\nuci set wireless.default_radio0.encryption=psk2\nuci set wireless.default_radio0.key=OpenWrt1234\n```\nStep2: Setup LAN segment network\n```\nuci set network.lan.device=wlan0\nuci set network.lan.ipaddr=192.168.4.1\n```\n'uci set network.lan.ipaddr=192.168.4.1' is the LAN-side IP address of the router.\nIn this example, it's set to 192.168.4.1, but if the user specifies a different IP address,\nplease follow their instructions.\nStep3: Setup WAN segment network\n```\nuci set network.wan=interface\nuci set network.wan.device=eth0\nuci set network.wan.proto=dhcp\n```\nIn the initial settings, there is no 'wan' section in the network configuration,\nso you need to create a new 'wan' section by executing 'uci set network.wan=interface'.\n","role":"system"},{"content":"Hello","role":"user"},{"content":"Hello! 👋  What can I help you with today? 😊 \n\nDo you have any questions about OpenWrt settings or would you like me to suggest changes for your network configuration? \n","role":"assistant"}]}]}
`  

When sending a request, set the id field (Ex:`0132179937`). The value of this id should be specified as the id included in the response of the base information retrieval or the initial conversation. The chat data corresponding to that id will be returned as the response.

# oasis ubus objects and methods
```
root@OpenWrt:~# ubus -v list oasis
'oasis' @689f0349
        "load_icon_info":{}
        "select_icon":{"using":"String"}
        "load_sysmsg_list":{}
        "load_sysmsg_data":{}
        "delete_icon":{"target":"String"}
        "add_sysmsg_data":{"title":"String","message":"String"}
        "config":{}
        "base_info":{}
        "analize":{"message":"String"}
        "update_sysmsg_data":{"target":"String","title":"String","message":"String"}
        "delete_sysmsg_data":{"target":"String"}
        "confirm":{}
        "select_ai_service":{"id":"String","name":"String","model":"String"}
root@OpenWrt:~# ubus -v list oasis.chat
'oasis.chat' @b4e0a13c
        "delete":{"id":"String"}
        "list":{}
        "append":{"content2":"String","id":"String","role2":"String","role1":"String","content1":"String"}
        "create":{"content3":"String","content2":"String","content1":"String","role2":"String","role1":"String","role3":"String"}
        "load":{"id":"String"}
        "send":{"id":"String","sysmsg_key":"String","message":"String"}
root@OpenWrt:~# ubus -v list oasis.title
'oasis.title' @bb1a58e9
        "auto_set":{"id":"String"}
        "manual_set":{"id":"String","title":"String"}
```


# Dependency Package
- lua-curl-v3
- luci-compat

## License

This project is licensed under the MIT License.

### Third-party licenses

This project includes the [Material Icons](https://github.com/google/material-design-icons) font by Google,
licensed under the Apache License, Version 2.0.
