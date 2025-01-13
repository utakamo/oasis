# OpenWrt AI Assistant Application - Oasis (ver 1.0)
> [!IMPORTANT]
> 
> **Support AI Service**
> - OpenAI
> - Ollama

This software provides the ability to link OpenWrt and AI. Based on user input, the AI provides the optimal settings for OpenWrt; the OpenWrt device itself analyzes the information provided by the AI, verifies the validity of that information, and then notifies the user.

|  Application  |         description       |
| :---: | :---  |
|   oasis    |   AI chat core software (provides stand-alone CUI-based chat functionality)   |
|  luci-app-oasis |   This is a plugin to use AI chat from within LuCI's WebUI. (base software is oasis)  ||  ルシアプリオアシス |   LuCIのWebUI内からAIチャットを利用するためのプラグインです。 (ベースソフトはoasis) |
<img width="895" alt="image" src="https://github.com/user-attachments/assets/fd6c788e-47ba-4385-acce-0e6a3e3cd367" />

> [!NOTE]
> This software can be installed on all OpenWrt target devices. However, the dependent package lua-curl-v3 must be pre-installed or available for download and installation from the repository for the target device.

## How to install luci-app-oasis
Dependency: oasis, lua-curl-v3, luci-compat
```
root@OpenWrt:~# opkg install oasis_1.0-r1_all.ipk
root@OpenWrt:~# opkg install luci-app-oasis_1.0-r1_all.ipk
root@OpenWrt:~# service rpcd reload
```
> [!IMPORTANT]
> This software uses LuCI's CBI (Configuration Bind Inteface). Therefore, it also depends on the luci-compat package. However, most OpenWrt device environments come pre-installed from the start.

## AI Setting
[Main] ---> [Network] ---> [Oasis] ---> [Setting]
<img width="849" alt="oasis_openwrt_chat_setting" src="https://github.com/user-attachments/assets/360fd2f2-37e2-498a-82e2-3dbc7ab6a56e">

> [!NOTE]
> If you want to use OpenAI, you need to set the Endpoint to the following URL.>
> https://api.openai.com/v1/chat/completions

> [!NOTE]
> If you want Ollama and OpenWrt to work together, you must set the Ollama parameters (OLLAMA_HOST and OLLAMA_ORIGINS) with the values shown below.>
> ```
> OLLAMA_HOST=0.0.0.0
> OLLAMA_ORIGINS=*
> ```
> My technical blog has an introductory page on the above Ollama setup, which describes the setup on Windows and Linux (Japanese Page).
> https://utakamo.com/article/ai/llm/ollama/setup/index.html#network-support
>
> Ollama Endpoint Format: ```http://<Your Ollama PC Address>:11434/api/chat ```

## Chat with AI
[Main] ---> [Network] ---> [Oasis] ---> [Chat with AI]
<img width="895" alt="image" src="https://github.com/user-attachments/assets/fd6c788e-47ba-4385-acce-0e6a3e3cd367" />
<img width="887" alt="image" src="https://github.com/user-attachments/assets/5740b2d7-cb89-45a4-b614-421d2e850fb1" />
<img width="887" alt="image" src="https://github.com/user-attachments/assets/9f7b4839-de38-44d9-a0ce-4c4780d1bf82" />
<img width="887" alt="image" src="https://github.com/user-attachments/assets/d66ce3b4-70b6-4898-8dee-e0c470f44c05" />

## Ask OpenWrt Setting
Oasis is customizing the AI to specialize in OpenWrt. Therefore, it may prompt users to ask about OpenWrt. If a user requests configuration related to OpenWrt, the AI will suggest changes using UCI commands.  
<img width="884" alt="image" src="https://github.com/user-attachments/assets/90ffddee-4d09-4897-b163-b6eb5c244296" />  
When a configuration change is suggested by the AI using UCI commands, the internal system of OpenWrt recognizes that a configuration change has been proposed by the AI. It then notifies the user via a popup to apply the configuration change to the current runtime. The user can accept the configuration change by pressing the Apply button.  
<img width="886" alt="image" src="https://github.com/user-attachments/assets/bd1ff33d-36e8-49c2-b64e-3be78a2d2ce9" />  
After applying the settings, if the user can access the WebUI, they will be notified in the Oasis chat screen to finalize the configuration change suggested by the AI. The user can press the Finalize button to approve the configuration change, or press the Rollback button to reject it.  
<img width="882" alt="image" src="https://github.com/user-attachments/assets/758edf02-43f8-4c10-9e6c-55d07be94652" />  
<img width="865" alt="image" src="https://github.com/user-attachments/assets/0f24a905-40b3-43ce-925e-20cc2aba0d58" />  

## How to install only oasis
Dependency: lua-curl-v3
```
root@OpenWrt:~# opkg install oasis_1.0-r1_all.ipk
root@OpenWrt:~# service rpcd reload
```

## Commands
> [!IMPORTANT]
> Some commands may not be available.

```
root@OpenWrt:~# oasis
Usage: oasis <command> [[<options>] arguments]...

Options:
 -n <service>           Set the service name
 -u <url>               Set the url or ipaddr for ai service
 -k <api-key>           Set the api-key for ai service
 -m <model>             Set the llm model for ai service

Commands:
 - storage <path> [<chat-max>] (default: chat-max = 30)
 - add [<service> [<url> [<api-key> [<model> [<storage>]]]]]
 - change <service> [<options> <argument>]...
 - select [<service>]
 - delete <service>
 - chat [id=<chat-id>]
 - prompt <message>
 - delchat id=<chat-id>
 - sysrole [[<chat|prompt|call> [<options>] [<system message>]]
 - rename id=<chat-id> <title> 
 - list
 - call <script> <messsage>

Docs
        https://utakamo.com
```
## Usage
### Step1: Setting up ai service  
- Example of OpenAI
```
root@OpenWrt:~# oasis add
Service Name                   >> my-chatgpt
Endpoint(url)                  >> https://api.openai.com/v1/chat/completions
API KEY (leave blank if none)  >> <your_api-key>
LLM MODEL                      >> gpt-3.5-turbo
```

- Example of local ai service (Ollama) 
```
root@OpenWrt:~# oasis add
Service Name                   >> my-ollama
Endpoint(url)                  >> http://192.168.3.16:11434/api/chat       
API KEY (leave blank if none)  >>
LLM MODEL                      >> gemma2:2b
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

You :history
{"messages":[{"content":"Hello!","role":"user"},{"content":"Hello! 👋 How can I help you today? 😊 \n","role":"assistant"}],"model":"gemma2:2b"}

You :exit
```
|  chat cmd  |         description       |
| :---: | :---  |
|   exit    |   Terminate the chat with the AI.   |
|  history |   Display the chat history(JSON)  |

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
# oasis ubus objects and methods
```
root@OpenWrt:~# ubus -v list
'oasis' @5a0d497e
        "config":{}
'oasis.chat' @bd30aea7
        "delete":{"id":"String"}
        "list":{}
        "append":{"content2":"String","id":"String","role2":"String","role1":"String","content1":"String"}
        "load":{"id":"String"}
        "create":{"content1":"String","role2":"String","role1":"String","content2":"String"}
'oasis.title' @57866132
        "auto_set":{"id":"String"}
        "manual_set":{"id":"String","title":"String"}
```

# Dependency Package
- lua-curl-v3
- luci-compat
