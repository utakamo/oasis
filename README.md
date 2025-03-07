# OpenWrt AI Assistant Application - Oasis (v1.0)
> [!IMPORTANT]
> >
> **Support AI Service**
> - OpenAI
> - Ollama

This software provides the ability to link OpenWrt and AI. Based on user input, the AI provides the optimal settings for OpenWrt; the OpenWrt device itself analyzes the information provided by the AI, verifies the validity of that information, and then notifies the user.

|  Application  |         description       |
| :---: | :---  |
|   oasis    |   AI chat core software (provides stand-alone CUI-based chat functionality)   |
|  luci-app-oasis |   This is a plugin to use AI chat from within LuCI's WebUI. (base software is oasis)  |
<img width="943" alt="Image" src="https://github.com/user-attachments/assets/1c11fb13-2c44-4d23-818c-27fd17da9693" />

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
[Main] ---> [Network] ---> [Oasis] ---> [General Setting]
<img width="944" alt="Image" src="https://github.com/user-attachments/assets/6b5a7f07-0855-4199-918e-6fc09e1557bc" />

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
<img width="943" alt="Image" src="https://github.com/user-attachments/assets/1c11fb13-2c44-4d23-818c-27fd17da9693" />  
When chatting with AI for the first time, you can choose what topics to talk about. These options can be freely added or removed by the user in the System Message tab.
<img width="950" alt="Image" src="https://github.com/user-attachments/assets/3f585550-03fa-48ca-9b8c-644d2221bce8" />  
When a chat with AI begins, it is given a title and displayed in the chat list on the left side.
"Users can continue chatting with AI, and if there is chat data from the past, they can select it to resume the conversation.
<img width="947" alt="Image" src="https://github.com/user-attachments/assets/9542aa1a-98f8-4d76-b466-533d99d3c560" />  
Chat data can be renamed, exported, or deleted.
<img width="942" alt="Image" src="https://github.com/user-attachments/assets/10d013bc-cc9d-4f9c-bcc4-2cedd0466a8d" />

## Ask OpenWrt Setting
Oasis is customizing the AI to specialize in OpenWrt. Therefore, it may prompt users to ask about OpenWrt. If a user requests configuration related to OpenWrt, the AI will suggest changes using UCI commands.  
<img width="944" alt="Image" src="https://github.com/user-attachments/assets/7ce13aff-b7f3-4594-80f7-a04d8a1bf012" />  
When a configuration change is suggested by the AI using UCI commands, the internal system of OpenWrt recognizes that a configuration change has been proposed by the AI. It then notifies the user via a popup to apply the configuration change to the current runtime. The user can accept the configuration change by pressing the Apply button.  
<img width="946" alt="Image" src="https://github.com/user-attachments/assets/e1b7f41e-7b7a-4355-9438-4e621e9a2944" />
<img width="940" alt="Image" src="https://github.com/user-attachments/assets/6310c703-b2c3-49d5-b38a-ebab82c61896" />  
After applying the settings, if the user can access the WebUI, they will be notified in the Oasis chat screen to finalize the configuration change suggested by the AI. The user can press the Finalize button to approve the configuration change, or press the Rollback button to reject it.  
<img width="946" alt="Image" src="https://github.com/user-attachments/assets/081313e4-e3ad-405f-a75b-ff4a46c83684" />
> [!IMPORTANT]
> After a configuration change, if the user does not press the Finalize or Rollback button within 5 minutes (default), the configuration will automatically rollback (Rollback monitoring). This ensures that even if there was a configuration error that caused a brick, the system will return to the original, normal settings. Note: If the OpenWrt device is powered off during the rollback monitoring period, the rollback monitoring will resume upon restart.

## System Message List
In Oasis, users can create and save system messages to use when starting a chat with AI. System messages are preloaded data used by AI to respond to the user.
For example, add a message like the following as a system message to instruct the AI to interpret English and Japanese.
<img width="947" alt="Image" src="https://github.com/user-attachments/assets/6b3e41a7-d31c-47d7-9521-56c5a5a1e578" />  
Enter the instructions for the AI into the text area of 'Create System Message' and press the Add button to add it to the System Message List. This will register a new System Message called 'Translator.'
<img width="945" alt="Image" src="https://github.com/user-attachments/assets/f89b1b46-4bd4-432c-a5b0-fcb8d52ae8b7" />  
"When you return to the Chat with AI tab and start a new chat with the AI, 'Translator' will appear as a topic option.


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
root@OpenWrt:~# ubus -v list oasis
'oasis' @389d3561
        "confirm":{}
        "config":{}
root@OpenWrt:~# ubus -v list oasis.chat
'oasis.chat' @960d4912
        "delete":{"id":"String"}
        "list":{}
        "append":{"content2":"String","id":"String","role2":"String","role1":"String","content1":"String"}
        "load":{"id":"String"}
        "create":{"content3":"String","content2":"String","content1":"String","role2":"String","role1":"String","role3":"String"}
root@OpenWrt:~# ubus -v list oasis.title
'oasis.title' @621446c9
        "auto_set":{"id":"String"}
        "manual_set":{"id":"String","title":"String"}
```

# Dependency Package
- lua-curl-v3
- luci-compat
