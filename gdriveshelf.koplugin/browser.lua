-- Native KOReader widgets, with no dependency on Cover Browser's local database.
local B={}
function B.header(o)
 local V=require('ui/widget/verticalgroup');local Title=require('ui/widget/titlebar')
 local title=Title:new{title=o.title,subtitle=o.status,left_icon='chevron.left',left_icon_tap_callback=o.back,close_callback=o.close,
  title_hold_callback=o.info,width=o.width}
 local buttons=require('ui/widget/buttontable'):new{width=o.width,buttons={o.buttons},zero_sep=true}
 for index,entry in ipairs(o.buttons)do if entry.icon_file then
  local button=buttons.buttons_layout[1][index]
  if button then
   button.label_widget:free()
   button.label_widget=require('ui/widget/iconwidget'):new{file=entry.icon_file,width=button.icon_width,height=button.icon_height,is_icon=true,alpha=true}
   button.label_container[1]=button.label_widget
  end
 end end
 local titleInput=require('ui/widget/container/inputcontainer'):new{title}
 if o.info then
  local Geom=require('ui/geometry');local area=Geom:new{x=math.floor(o.width*.12),y=0,w=math.floor(o.width*.76),h=title:getHeight()}
  titleInput.ges_events={ShelfInfo={require('ui/gesturerange'):new{ges='tap',range=area}}}
  titleInput.onShelfInfo=function()o.info();return true end
 end
 local header=V:new{align='left',titleInput}
 if #o.buttons>0 then header[#header+1]=buttons end
 for _,bar in ipairs(o.bars or {})do
  header[#header+1]=require('ui/widget/textboxwidget'):new{text=bar.label,width=o.width-32,face=require('ui/font'):getFace('smallinfofont')}
  if bar.value then header[#header+1]=require('ui/widget/progresswidget'):new{width=o.width-32,height=14,percentage=bar.value,radius=0,bordersize=1,margin_h=1,margin_v=1}end
 end
 if o.summary then
  local row=require('ui/widget/horizontalgroup'):new{}
  if o.summary.cover_path then row[#row+1]=require('ui/widget/iconwidget'):new{file=o.summary.cover_path,width=math.floor(o.width*0.12),height=math.floor(o.width*0.16),scale_factor=0,is_icon=false}end
  row[#row+1]=require('ui/widget/textboxwidget'):new{text=o.summary.text,width=math.floor(o.width*0.8),face=require('ui/font'):getFace('smallinfofont'),height=o.summary.height,height_overflow_show_ellipsis=true}
  header[#header+1]=row
 end
 header.getHeight=function(h)return h:getSize().h end
 header.setTitle=function(_,text,refresh)title:setTitle(text,refresh)end
 header.setSubTitle=function(_,text,refresh)title:setSubTitle(text,refresh)end
 header.generateVerticalLayout=function()local layout=title:generateVerticalLayout();for _,row in ipairs(buttons.layout or {})do layout[#layout+1]=row end;return layout end
 return header
end
function B.gridClass(Menu)
 local Input=require('ui/widget/container/inputcontainer')
 local Geom=require('ui/geometry');local UI=require('ui/uimanager')
 local Cell=Input:extend{}
 function Cell:init()
  self.ges_events={TapSelect={require('ui/gesturerange'):new{ges='tap',range=self.dimen}},HoldSelect={require('ui/gesturerange'):new{ges='hold',range=self.dimen}}}
 end
 function Cell:onTapSelect()self.menu:onMenuSelect(self.entry);return true end
 function Cell:onHoldSelect()self.menu:onMenuHold(self.entry);return true end
 function Cell:onFocus()end
 function Cell:onUnfocus()end
 return Menu:extend{updateItems=function(m,selected,no_recalculate)
  m.item_group:clear();m.layout={};m.page_info:resetLayout();m.return_button:resetLayout();m.content_group:resetLayout();m:_recalculateDimen(no_recalculate)
  local columns=m.grid_columns or 3;local rows=math.ceil(m.perpage/columns)
  local width=math.floor(m.item_dimen.w/columns);local height=math.floor(m.item_dimen.h*m.perpage/rows)
  local H=require('ui/widget/horizontalgroup');local V=require('ui/widget/verticalgroup');local Center=require('ui/widget/container/centercontainer')
  local pictureHeight=math.floor(height*0.64);local font=require('ui/font'):getFace('smallinfofont')
  for y=1,rows do
   local group=H:new{};local focus={}
   for x=1,columns do
    local index=(m.page-1)*m.perpage+(y-1)*columns+x;local item=m.item_table[index]
    if item then
     item.idx=index
     local body=V:new{align='center'}
     if item.icon_file then
      local picture=require('ui/widget/iconwidget'):new{file=item.icon_file,width=math.floor(width*0.72),height=pictureHeight,scale_factor=0,is_icon=false,alpha=true}
      body[#body+1]=Center:new{dimen=Geom:new{w=width-12,h=pictureHeight},picture}
     end
     if item.folder_progress~=nil then body[#body+1]=require('ui/widget/progresswidget'):new{width=width-32,height=8,percentage=item.folder_progress,radius=0,bordersize=1,margin_h=0,margin_v=0}end
     body[#body+1]=require('ui/widget/textboxwidget'):new{text=item.text or '',face=font,width=width-20,height=math.floor(height*(item.icon_file and 0.29 or 0.65)),height_adjust=true,height_overflow_show_ellipsis=true,alignment='center'}
     local cell=Cell:new{dimen=Geom:new{w=width,h=height},entry=item,idx=index,menu=m,
      require('ui/widget/container/framecontainer'):new{padding=5,margin=0,bordersize=1,width=width,height=height,Center:new{dimen=Geom:new{w=width-12,h=height-12},body}}}
     group[#group+1]=cell;focus[#focus+1]=cell
    end
   end
   if #focus>0 then m.item_group[#m.item_group+1]=group;m.layout[#m.layout+1]=focus end
  end
  m:updatePageInfo(selected);m:mergeTitleBarIntoLayout();UI:setDirty(m,'ui')
 end}
end
return B
