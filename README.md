# 3DEM_cellblender

You need three files to deploy apps

`test.sh`
This file includes example commands that you can directly run on TACC systems. Test that this works before continuing. 

`wrapper.sh`
This file contains wrapper scripts with parameters that is implemented from the json. 

`cellblender.json`
Include details of application parameters, input, parameters and output. 

# App deployment

Setup Tapis environment to 3DEM tenant first and have permission set up to deploy apps to 3DEM execution system. </br>
```tapis apps create -F cellblender.json ```


