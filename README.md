# OpenWrt AI Support Application - aihelper
This application is currently under development...

## Commands
> [!IMPORTANT]
> Some commands may not be available.

```
root@OpenWrt:~# aihelper
Usage: aihelper <command> [[<options>] arguments]...

Options:
 -n <service>           Set the service name
 -u <url>               Set the url or ipaddr for ai service
 -k <api-key>           Set the api-key for ai service
 -m <model>             Set the llm model for ai service
 -s enable or disable   Set the storage enable/disable

Commands:
 - storage <path> [<chat-max>] (default: chat-max = 30)
 - add [<service> [<url> [<api-key> [<model> [<storage>]]]]]
 - change <service> [<options> <argument>]...
 - select [<service>]
 - delete <service>
 - chat [id=<chat-id>]
 - prompt
 - delchat <id>
 - rename <id> <title>
 - list [[chat] [knowledge]]
 - test <service>
 - call <script> <messsage>

Docs
        https://utakamo.com
```
## Usage
### Step1: Setting up ai service  
- Example of chatgpt
```
Service Name                   >> my-chatgpt
Endpoint(url)                  >> https://api.openai.com/v1/chat/completions
API KEY (leave blank if none)  >> <your_api-key>
LLM MODEL                      >> gpt-3.5-turbo
```
- Example of local ai service (Ollama) 
```
root@OpenWrt:~# aihelper add
Service Name                   >> my-ollama
Endpoint(url)                  >> http://192.168.3.12:11434/api/chat       
API KEY (leave blank if none)  >>
LLM MODEL                      >> gemma2:2b
``````
> [!NOTE]
> If you want to use chatgpt, you need to set the Endpoint to the following URL.
> https://api.openai.com/v1/chat/completions

### Step2: Select AI Service
- The first service registered with the aihelper add command is selected.　
<img width="416" alt="aihelper_select_service01" src="https://github.com/user-attachments/assets/03eec7e6-491e-4320-b08f-b61b0d04bbaa"><br>
- To switch to another AI service, run aihelper select <service-name>. The following is an example of switching the service in use to my-ollama.
<img width="416" alt="aihelper_select_service02" src="https://github.com/user-attachments/assets/e3b4acea-f4dd-4e4f-b120-83aeb215d8d1">

### Step3: Example of chat with ai
```
root@OpenWrt:~# aihelper chat
You :Hello!

gemma2:2b
Hello! 👋  

How can I help you today? 😄
Title:ConversationStart  ID:7772532380

You :show
{"messages":[{"content":"Hello!","role":"user"},{"content":"Hello! 👋 How can I help you today? 😊 \n","role":"assistant"}],"model":"gemma2:2b"}

You :exit
The chat is over.
```
'exit' ... End chat  
'show' ... Display the chat history(JSON)

## Load past chats and resume conversation.
Confirm Chat ID
```
root@OpenWrt:~# aihelper list
-----------------------------------------------------
 No. | title                          | id
-----------------------------------------------------
[ 1]: Hello                            5727149461
[ 2]: ConversationStart                7772532380
```
Resume conversation with the AI by specifying the chat ID.
```
root@OpenWrt:~# aihelper chat id=7772532380
You :Hello!

gemma2:2b
Hello! 👋 How can I help you today? 😊

You :
```

# Dependency Package
- lua-curl-v3
