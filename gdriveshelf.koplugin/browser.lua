-- Native KOReader widgets, with no dependency on Cover Browser's local database.
local B={}
function B.header(o)
 local V=require('ui/widget/verticalgroup');local Title=require('ui/widget/titlebar')
 local Screen=require('device').screen;local pad=Screen:scaleBySize(12);local gap=Screen:scaleBySize(8)
 local Frame=require('ui/widget/container/framecontainer');local VS=require('ui/widget/verticalspan')
 local function inset(widget)return Frame:new{padding=0,padding_left=pad,padding_right=pad,bordersize=0,widget}end
 local title=Title:new{title=o.title,subtitle=o.status,left_icon='chevron.left',left_icon_tap_callback=o.back,close_callback=o.close,
  title_hold_callback=o.info,width=o.width}
 for _,button in ipairs(o.buttons)do button.icon_width=Screen:scaleBySize(22);button.icon_height=Screen:scaleBySize(22);button.height=Screen:scaleBySize(44)end
 local buttons=require('ui/widget/buttontable'):new{width=o.width-2*pad,buttons={o.buttons}}
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
 local H=require('ui/widget/horizontalgroup')
 local HS=require('ui/widget/horizontalspan')
 local Button=require('ui/widget/button')
 local Font=require('ui/font')
 local Text=require('ui/widget/textboxwidget')
 local header_actions,header_focus={},{}
 if o.conflict then header_actions[#header_actions+1]={icon='notice-warning',callback=o.conflict}end
 if o.collapse then header_actions[#header_actions+1]={icon='chevron.up',rotation=o.collapsed and 180 or 0,callback=o.collapse}end
 if #o.buttons>0 then header[#header+1]=inset(buttons);header[#header+1]=VS:new{width=gap}end
 local activity
 if o.activity then
  activity=require('ui/widget/button'):new{text=o.activity,width=o.width-2*pad,height=Screen:scaleBySize(32),
   text_font_face='smallinfofont',text_font_size=16,text_font_bold=false,align='left',avoid_text_truncation=false,
   bordersize=0,padding_h=Screen:scaleBySize(4),padding_v=0,callback=o.activity_callback}
  header[#header+1]=inset(activity);header[#header+1]=VS:new{width=gap}
 end
 for _,bar in ipairs(o.bars or {})do
  local block=V:new{align='left',require('ui/widget/textboxwidget'):new{text=bar.label,width=o.width-2*pad,face=require('ui/font'):getFace('smallinfofont')}}
  if bar.value then
   block[#block+1]=VS:new{width=Screen:scaleBySize(4)}
   block[#block+1]=require('ui/widget/progresswidget'):new{width=o.width-2*pad,height=Screen:scaleBySize(6),percentage=bar.value,radius=0,bordersize=1,margin_h=1,margin_v=1}
  end
  header[#header+1]=inset(block);header[#header+1]=VS:new{width=gap}
 end
 local compact_width=o.width-2*pad
 local function smallButton(spec)
  local button=Button:new{icon=spec.icon,icon_rotation_angle=spec.rotation or 0,icon_width=Screen:scaleBySize(15),icon_height=Screen:scaleBySize(15),
   width=Screen:scaleBySize(32),height=Screen:scaleBySize(32),padding_h=0,padding_v=0,bordersize=0,callback=spec.callback}
  header_focus[#header_focus+1]=button
  return button
 end
 if o.summary then
  local row=H:new{align='top'}
  local coverHeight=math.min(o.summary.height,Screen:scaleBySize(144))
  local coverWidth=math.floor(coverHeight*.72)
  local textWidth=compact_width
  if o.summary.cover_path then
   row[#row+1]=require('ui/widget/iconwidget'):new{file=o.summary.cover_path,width=coverWidth,height=coverHeight,scale_factor=0,is_icon=false}
   row[#row+1]=HS:new{width=gap};textWidth=textWidth-coverWidth-gap
  end
  local actions=H:new{align='center'}
  for _,spec in ipairs(header_actions)do actions[#actions+1]=smallButton(spec)end
  local titleWidth=textWidth-(#header_actions>0 and actions:getSize().w+gap or 0)
  local label=Text:new{text=o.summary.text,width=titleWidth,face=Font:getFace('cfont',20),bold=true,
   height=math.floor(coverHeight*.42),height_adjust=true,height_overflow_show_ellipsis=true}
  local labelRow=H:new{align='top',label}
  if #header_actions>0 then labelRow[#labelRow+1]=HS:new{width=gap};labelRow[#labelRow+1]=actions end
  local details=V:new{align='left',labelRow}
  local function addLine(value,height)
   if not value or value=='' or height<Screen:scaleBySize(16)then return end
   local widget=Text:new{text=value,width=textWidth,face=Font:getFace('smallinfofont'),height=height,
    height_adjust=true,height_overflow_show_ellipsis=true}
   details[#details+1]=VS:new{width=math.floor(gap/2)}
   details[#details+1]=widget
  end
  addLine(o.summary.stats,Screen:scaleBySize(24))
  addLine(o.summary.description,coverHeight-details:getSize().h-gap)
  details:resetLayout()
  row[#row+1]=details
  header[#header+1]=inset(row);header[#header+1]=VS:new{width=gap}
 elseif #header_actions>0 then
  local row=H:new{align='center'}
  for _,spec in ipairs(header_actions)do row[#row+1]=smallButton(spec)end
  header[#header+1]=inset(row)
 end
 local resume
 if o.resume then
  resume=Button:new{text=o.resume.text,enabled=o.resume.enabled,width=compact_width,height=Screen:scaleBySize(36),
   text_font_face='cfont',text_font_size=16,align='left',avoid_text_truncation=false,padding_h=gap,padding_v=0,
   callback=o.resume.callback}
  header[#header+1]=inset(resume);header[#header+1]=VS:new{width=gap}
 end
 header.bindMenu=function(_,menu)title.show_parent=menu end
 header.getHeight=function(h)return h:getSize().h end
 header.setTitle=function(_,text,refresh)title:setTitle(text,refresh)end
 header.setSubTitle=function(_,text,refresh)title:setSubTitle(text,refresh)end
 header.setActivity=function(_,text)
  if not activity or text==activity.text then return end
  activity:setText(text,activity.width);activity:refresh()
 end
 header.generateVerticalLayout=function()local layout=title:generateVerticalLayout();for _,row in ipairs(buttons.layout or {})do layout[#layout+1]=row end;if activity then layout[#layout+1]={activity}end;if #header_focus>0 then layout[#layout+1]=header_focus end;if resume then layout[#layout+1]={resume}end;return layout end
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
  local Screen=require('device').screen;local outer=Screen:scaleBySize(12);local gap=Screen:scaleBySize(8);local inner=Screen:scaleBySize(8)
  local width=math.floor((m.item_dimen.w-2*outer-(columns-1)*gap)/columns)
  local height=math.floor((m.available_height-2*outer-(rows-1)*gap)/rows)
  local H=require('ui/widget/horizontalgroup');local V=require('ui/widget/verticalgroup');local Center=require('ui/widget/container/centercontainer')
  local HS=require('ui/widget/horizontalspan');local VS=require('ui/widget/verticalspan')
  local contentWidth=width-2*inner-2;local contentHeight=height-2*inner-2
  local font=require('ui/font'):getFace('cfont',math.max(12,math.floor(m.font_size*.78)))
  local detailFont=require('ui/font'):getFace('smallinfofont',math.max(10,math.floor(m.font_size*.52)))
  m.item_group[#m.item_group+1]=VS:new{width=outer}
  for y=1,rows do
   local group=H:new{HS:new{width=outer}};local focus={}
   for x=1,columns do
    local index=(m.page-1)*m.perpage+(y-1)*columns+x;local item=m.item_table[index]
    if item then
     item.idx=index
     local Text=require('ui/widget/textboxwidget')
     local spacer=math.floor(gap/2);local progressHeight=Screen:scaleBySize(3)
     local badges
     if item.card_left or item.card_right then
      local TW=require('ui/widget/textwidget')
      local function badge(value,icon)
       local label=TW:new{text=value or '',face=detailFont}
       if not icon or not value or value==''then return label end
       local size=Screen:scaleBySize(11)
       return H:new{align='center',require('ui/widget/iconwidget'):new{icon=icon,width=size,height=size},HS:new{width=spacer},label}
      end
      local left=badge(item.card_left,item.card_left_icon);local right=badge(item.card_right,item.card_right_icon)
      local remaining=contentWidth-left:getSize().w-right:getSize().w
      if remaining>=gap then
       badges=H:new{left,HS:new{width=remaining},right}
      else
       left:free();right:free()
       badges=Text:new{text=item.card_fallback or table.concat({item.card_left or '',item.card_right or ''},' · '),face=detailFont,width=contentWidth,
        height=math.floor(contentHeight*.20),height_adjust=true,height_overflow_show_ellipsis=true,alignment='left'}
      end
     end
     local bodyHeight=contentHeight-(badges and badges:getSize().h+spacer or 0)
     local label=Text:new{text=item.card_title or item.text or '',face=font,width=contentWidth,height=math.floor(bodyHeight*(item.icon_file and .35 or .50)),height_adjust=true,height_overflow_show_ellipsis=true,alignment='center'}
     local detail=item.card_details and item.card_details~=''and Text:new{text=item.card_details,face=detailFont,width=contentWidth,height=math.floor(bodyHeight*.35),height_adjust=true,height_overflow_show_ellipsis=true,alignment='center'}or nil
     local textHeight=label:getSize().h+(detail and detail:getSize().h+spacer or 0)+(item.folder_progress~=nil and progressHeight+spacer or 0)
     local body=V:new{align='center'}
     if item.icon_file then
      local pictureHeight=math.max(1,math.min(math.floor(bodyHeight*.83),bodyHeight-textHeight-spacer))
      local picture=require('ui/widget/iconwidget'):new{file=item.icon_file,width=contentWidth,height=pictureHeight,scale_factor=0,is_icon=false,alpha=true}
      body[#body+1]=Center:new{dimen=Geom:new{w=contentWidth,h=pictureHeight},picture}
      body[#body+1]=VS:new{width=spacer}
     end
     body[#body+1]=label
     if detail then body[#body+1]=VS:new{width=spacer};body[#body+1]=detail end
     if item.folder_progress~=nil then
      body[#body+1]=VS:new{width=spacer}
      body[#body+1]=require('ui/widget/progresswidget'):new{width=contentWidth,height=progressHeight,percentage=item.folder_progress,radius=0,bordersize=1,margin_h=0,margin_v=0}
     end
     local content=V:new{align='left'}
     if badges then content[#content+1]=badges;content[#content+1]=VS:new{width=spacer}end
     content[#content+1]=Center:new{dimen=Geom:new{w=contentWidth,h=bodyHeight},body}
     local cell=Cell:new{dimen=Geom:new{w=width,h=height},entry=item,idx=index,menu=m,
      require('ui/widget/container/framecontainer'):new{padding=inner,margin=0,bordersize=1,Center:new{dimen=Geom:new{w=contentWidth,h=contentHeight},content}}}
     group[#group+1]=cell;focus[#focus+1]=cell
    else group[#group+1]=HS:new{width=width}end
    if x<columns then group[#group+1]=HS:new{width=gap}end
   end
   group[#group+1]=HS:new{width=m.item_dimen.w-outer-width*columns-gap*(columns-1)}
   if #focus>0 then
    if #m.layout>0 then m.item_group[#m.item_group+1]=VS:new{width=gap}end
    m.item_group[#m.item_group+1]=group;m.layout[#m.layout+1]=focus
   end
  end
  m:updatePageInfo(selected);m:mergeTitleBarIntoLayout();UI:setDirty(m,'ui')
 end}
end
return B
