# OpenWrt AI Assistant Application - Oasis (Beta)
> [!IMPORTANT]
> This application is currently under development...  
> Currently, this software only implements the ability to chat with AI.
> 
> **Support AI Service**
> - OpenAI
> - Ollama

This software provides the ability to link OpenWrt and AI. Based on user input, the AI provides the optimal settings for OpenWrt; the OpenWrt device itself analyzes the information provided by the AI, verifies the validity of that information, and then notifies the user.

|  Application  |         description       |
| :---: | :---  |
|   oasis    |   AI chat core software (provides stand-alone CUI-based chat functionality)   |
|  luci-app-oasis |   This is a plugin to use AI chat from within LuCI's WebUI. (base software is oasis)  |
<img width="878" alt="image" src="https://github.com/user-attachments/assets/cc1d54f5-9dfb-4f06-9613-0ce73b37904d" />

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
<img width="854" alt="oasis_openwrt_chat_window" src="https://github.com/user-attachments/assets/d70ff6e2-313d-48af-96d5-84c193e74ff4">

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
